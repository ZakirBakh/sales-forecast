"""Построение признаков для прогноза на HORIZON дней вперёд.

Ключевая идея (прямой многошаговый прогноз): чтобы спрогнозировать продажи
в день t, модель использует только значения ряда до дня t − HORIZON.
Тогда одна и та же модель честно даёт прогноз на любой день в пределах
4 недель вперёд, и в признаки никогда не попадает будущее.

Группы признаков:
  * лаги — продажи 28, 35, 42 … 364 дня назад (кратно 7 — тот же день недели);
  * скользящие статистики по «известному прошлому» (окно заканчивается за 28 дней до t);
  * тренд — отношение недавнего уровня к уровню за квартал;
  * год назад — уровень продаж в то же время прошлого года;
  * календарь — день недели, праздники, длинные выходные, день месяца;
  * флаг ограничения выдач кредитов и его доля в окне лагов;
  * идентификатор ряда и группы продукта (категориальные).
"""
import numpy as np
import pandas as pd

from .calendar_kg import calendar_features
from .config import HORIZON

LAGS = [28, 35, 42, 49, 56, 63, 91, 182, 364]
CAT_FEATURES = ["series", "product_group"]


def _per_series(g: pd.DataFrame, h: int) -> pd.DataFrame:
    # Лаги строим по y_feat (y без известных разовых событий), если такая колонка есть
    y = g["y_feat"] if "y_feat" in g else g["y"]
    known = y.shift(h)                       # последнее значение, известное на момент прогноза
    out = pd.DataFrame(index=g.index)
    for lag in LAGS:
        if lag >= h:
            out[f"lag_{lag}"] = y.shift(lag)
    # Среднее по тому же дню недели за 4 и 8 последних известных недель
    out["same_dow_mean_4"] = pd.concat([y.shift(h + 7 * k) for k in range(4)], axis=1).mean(axis=1)
    out["same_dow_mean_8"] = pd.concat([y.shift(h + 7 * k) for k in range(8)], axis=1).mean(axis=1)
    for w in (7, 14, 28, 56, 91):
        out[f"roll_mean_{w}"] = known.rolling(w, min_periods=max(3, w // 2)).mean()
    out["roll_std_28"] = known.rolling(28, min_periods=14).std()
    out["roll_max_28"] = known.rolling(28, min_periods=14).max()
    out["zero_share_28"] = (known == 0).astype(float).where(known.notna()).rolling(28, min_periods=14).mean()
    # Средние продажи только по рабочим дням (у кредитов в выходные почти ноль)
    work_known = known.where(g["is_nonwork"].shift(h) == 0)
    out["workday_mean_28"] = work_known.rolling(28, min_periods=10).mean()
    # Тренд: недавний уровень к квартальному
    out["trend_7_91"] = out["roll_mean_7"] / (out["roll_mean_91"] + 1)
    out["trend_28_91"] = out["roll_mean_28"] / (out["roll_mean_91"] + 1)
    # Год назад: уровень вокруг того же дня прошлого года (окно t-377 … t-350)
    out["yoy_mean_28"] = y.shift(364 - 14).rolling(28, min_periods=14).mean()
    # Доля дней с ограничением выдач в окне, из которого взяты лаги
    out["limit_share_lag_window"] = g["credit_supply_limit"].shift(h).rolling(28, min_periods=1).mean()
    out["days_since_start"] = np.arange(len(g))
    return out


def add_future(df: pd.DataFrame, days: int = HORIZON, credit_limit: int = 0) -> pd.DataFrame:
    """Добавляет в конец каждого ряда `days` будущих дней с неизвестным y (NaN).

    credit_limit — сценарий: будет ли действовать ограничение выдач кредитов
    в прогнозном периоде (0 = нет, 1 = да).
    """
    last = df["date"].max()
    future_dates = pd.date_range(last + pd.Timedelta(days=1), periods=days)
    meta = df.drop_duplicates("series")[["series", "product_group"]]
    fut = meta.merge(pd.DataFrame({"date": future_dates}), how="cross")
    fut["y"] = np.nan
    fut["credit_supply_limit"] = np.where(fut["product_group"] == "Кредит", credit_limit, 0)
    out = pd.concat([df, fut], ignore_index=True)
    return out.sort_values(["series", "date"]).reset_index(drop=True)


def build_features(df: pd.DataFrame, horizon: int = HORIZON) -> pd.DataFrame:
    """Возвращает исходную таблицу + все признаки (одна строка = день × ряд)."""
    df = df.sort_values(["series", "date"]).reset_index(drop=True)
    cal = calendar_features(df["date"])
    df = pd.concat([df, cal], axis=1)
    parts = [ _per_series(g, horizon) for _, g in df.groupby("series", sort=False) ]
    feats = pd.concat(parts).loc[df.index]
    out = pd.concat([df, feats], axis=1)
    for c in CAT_FEATURES:
        out[c] = out[c].astype("category")
    return out


def feature_columns(df: pd.DataFrame) -> list:
    """Все колонки-признаки (без даты и целевой переменной)."""
    drop = {"date", "y", "y_feat"}
    return [c for c in df.columns if c not in drop]


def usable_rows(df: pd.DataFrame) -> pd.Series:
    """Строки с достаточной историей: нужны хотя бы квартальные статистики."""
    return df["roll_mean_91"].notna()
