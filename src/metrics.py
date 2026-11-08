"""Метрики качества прогноза.

Основная метрика — WAPE (Weighted Absolute Percentage Error):
    WAPE = Σ|факт − прогноз| / Σ факт.
Почему она, а не MAPE: в рядах много дней с нулевыми продажами (выходные у
кредитов), и MAPE на нулях делится на ноль. WAPE устойчива к нулям и читается
как «на сколько процентов от объёма продаж ошибается прогноз».

Дополнительно:
  * MAE / RMSE — ошибка в штуках (RMSE сильнее наказывает большие промахи);
  * Bias — систематический сдвиг: > 0 модель завышает, < 0 занижает;
  * WAPE по неделям и месяцам — то, что важно бизнесу для планирования
    (дневные ошибки частично взаимно гасятся на горизонте недели / месяца).
"""
import numpy as np
import pandas as pd


def wape(y, p) -> float:
    y, p = np.asarray(y, float), np.asarray(p, float)
    return float(np.abs(y - p).sum() / max(np.abs(y).sum(), 1e-9))


def bias(y, p) -> float:
    y, p = np.asarray(y, float), np.asarray(p, float)
    return float((p - y).sum() / max(np.abs(y).sum(), 1e-9))


def mae(y, p) -> float:
    return float(np.mean(np.abs(np.asarray(y, float) - np.asarray(p, float))))


def rmse(y, p) -> float:
    return float(np.sqrt(np.mean((np.asarray(y, float) - np.asarray(p, float)) ** 2)))


def aggregated_wape(df: pd.DataFrame, pred_col: str, freq: str) -> float:
    """WAPE после суммирования факта и прогноза по неделе ('W') или месяцу ('MS')."""
    g = df.groupby(["series", pd.Grouper(key="date", freq=freq)])[["y", pred_col]].sum()
    return wape(g["y"], g[pred_col])


def summary(df: pd.DataFrame, pred_cols: list) -> pd.DataFrame:
    """Сводная таблица метрик по всем рядам сразу для нескольких моделей."""
    rows = []
    for c in pred_cols:
        per_series = pd.Series({s: wape(g["y"], g[c]) for s, g in df.groupby("series", observed=True)})
        rows.append({
            "model": c,
            "WAPE": wape(df["y"], df[c]),
            "WAPE_week": aggregated_wape(df, c, "W"),
            "WAPE_month": aggregated_wape(df, c, "MS"),
            "macro_WAPE": per_series.mean(),     # среднее по рядам: каждый ряд с равным весом
            "MAE": mae(df["y"], df[c]),
            "RMSE": rmse(df["y"], df[c]),
            "Bias": bias(df["y"], df[c]),
        })
    return pd.DataFrame(rows).set_index("model")


def per_series(df: pd.DataFrame, pred_col: str) -> pd.DataFrame:
    """Метрики по каждому ряду отдельно — для анализа ошибок."""
    rows = []
    for (pg, s), g in df.groupby(["product_group", "series"], observed=True):
        rows.append({"product_group": pg, "series": s,
                     "fact_total": g["y"].sum(), "pred_total": g[pred_col].sum(),
                     "WAPE": wape(g["y"], g[pred_col]),
                     "WAPE_week": aggregated_wape(g, pred_col, "W"),
                     "Bias": bias(g["y"], g[pred_col])})
    return pd.DataFrame(rows).set_index(["product_group", "series"]).sort_values("fact_total", ascending=False)
