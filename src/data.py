"""Загрузка дневных рядов продаж и приведение их к виду «одна строка = день × ряд»."""
import pandas as pd

from .config import DATA, EXCLUDED_SERIES


def load_series(path=DATA) -> pd.DataFrame:
    """Читает выгрузку и возвращает таблицу для модели.

    Колонки результата:
      date, product_group (Карта / Кредит / Депозит), series (идентификатор ряда),
      y (продажи за день, целевая переменная), credit_supply_limit (флаг ограничения выдач).

    Что делаем и почему:
      1. Убираем ряды без продаж («Архивные» депозиты — только закрытия).
      2. Ряд = «Группа: подгруппа», чтобы названия были уникальны между картами,
         кредитами и депозитами.
      3. Обрезаем начало ряда до первой продажи: дни до запуска продукта (например,
         копилка запущена 12.05.2025) — не «нулевой спрос», а отсутствие продукта,
         и такие нули только испортили бы обучение.
      4. Проверяем, что внутри каждого ряда нет пропущенных дней.
    """
    df = pd.read_csv(path, parse_dates=["date"])
    df = df[~df["series_group"].isin(EXCLUDED_SERIES)].copy()
    df["series"] = df["product_group"] + ": " + df["series_group"]
    df = df.rename(columns={"sales_count": "y"})
    df = df[["date", "product_group", "series", "y", "credit_supply_limit"]]
    df["y"] = df["y"].astype(float)
    df["credit_supply_limit"] = df["credit_supply_limit"].fillna(0).astype(int)

    first_sale = df[df["y"] > 0].groupby("series")["date"].min().rename("first_sale")
    df = df.merge(first_sale, on="series")
    df = df[df["date"] >= df["first_sale"]].drop(columns="first_sale")
    df = df.sort_values(["series", "date"]).reset_index(drop=True)

    # Контроль: в каждом ряду дни идут подряд, без дыр
    gaps = df.groupby("series")["date"].apply(lambda s: (s.diff().dt.days.dropna() != 1).sum())
    assert gaps.sum() == 0, f"Пропущенные дни в рядах: {gaps[gaps > 0].to_dict()}"
    return df


def series_info(df: pd.DataFrame) -> pd.DataFrame:
    """Краткая сводка по рядам: период, объём, доля нулевых дней."""
    g = df.groupby(["product_group", "series"])
    out = g.agg(start=("date", "min"), end=("date", "max"), days=("date", "size"),
                total=("y", "sum"), mean_per_day=("y", "mean"),
                zero_share=("y", lambda s: (s == 0).mean()))
    return out.sort_values("total", ascending=False)


def add_feature_target(df: pd.DataFrame, events) -> pd.DataFrame:
    """Колонка y_feat — версия y для построения ЛАГОВ и скользящих признаков.

    В дни известных разовых событий (массовые выпуски карт) y_feat заменяется
    обычным уровнем ряда: медианой рабочих дней за 4 недели до события
    (в выходные и праздники — 0). Иначе событие «застревает» в лагах ещё на
    8 недель и модель завышает прогноз. Целевая переменная y не меняется.
    """
    from .calendar_kg import days_off
    off = days_off()
    df = df.copy()
    df["y_feat"] = df["y"]
    for s, a, b, _ in events:
        a, b = pd.Timestamp(a), pd.Timestamp(b)
        hist = df[(df.series == s) & (df.date >= a - pd.Timedelta(days=28)) & (df.date < a)]
        work = hist[(hist.date.dt.dayofweek < 5) & ~hist.date.isin(off)]
        level = work["y"].median()
        m = (df.series == s) & df.date.between(a, b)
        nonwork = (df.date.dt.dayofweek >= 5) | df.date.isin(off)
        df.loc[m, "y_feat"] = level
        df.loc[m & nonwork, "y_feat"] = 0.0
    return df
