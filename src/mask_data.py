"""Обезличивание данных для публикации (GitHub, отчёт, презентация).

Каждый ряд умножается на свой секретный коэффициент: либо 0,55–0,8, либо 1,25–1,6
(значения около 1 не берутся, чтобы объёмы не совпали с реальными), суммы — ещё
на отдельный общий коэффициент. Ставки и сроки продуктов в обезличенную версию
не попадают: по ним можно узнать банк. Даты, нули, недельный профиль,
праздники и всплески сохраняются, поэтому EDA и модель на обезличенных
данных дают те же выводы, а реальные объёмы банка и структура продаж скрыты.

Запуск:  MASK_SEED=<секретное число> python -m src.mask_data
Секрет (MASK_SEED) нигде не сохраняется — держите его у себя.
Если MASK_SEED не задан, берётся случайный (тогда маску нельзя воспроизвести).
"""
import os
import secrets

import numpy as np
import pandas as pd

from .config import DATA_BYCH_MASKED, DATA_BYCH_RAW, DATA_MASKED, DATA_RAW

COUNT_COLS = ["sales_count", "cards_count", "closures_count", "early_closures"]
DROP_COLS = ["wavg_rate", "avg_term_months"]


def draw_factor(rng: np.random.Generator) -> float:
    """Коэффициент для ряда: заметно меньше или заметно больше 1."""
    if rng.random() < 0.5:
        return float(rng.uniform(0.55, 0.8))
    return float(rng.uniform(1.25, 1.6))


def mask(df: pd.DataFrame, rng: np.random.Generator, factors: dict, amount_k: float) -> pd.DataFrame:
    df = df.copy()
    key = df["product_group"] + "|" + df["series_group"]
    f = key.map(factors)
    for c in COUNT_COLS:
        if c in df:
            df[c] = (df[c] * f).round().astype("Int64")
    if "sales_amount" in df:
        df["sales_amount"] = (df["sales_amount"] * f * amount_k).round(-3)
    # ставки и сроки не публикуем
    return df.drop(columns=[c for c in DROP_COLS if c in df])


def main():
    seed = int(os.environ.get("MASK_SEED", secrets.randbits(32)))
    rng = np.random.default_rng(seed)
    raw = pd.read_csv(DATA_RAW, parse_dates=["date"])
    keys = sorted((raw["product_group"] + "|" + raw["series_group"]).unique())
    factors = {k: draw_factor(rng) for k in keys}
    amount_k = rng.uniform(0.3, 0.7)
    mask(raw, rng, factors, amount_k).to_csv(DATA_MASKED, index=False, encoding="utf-8-sig")
    if DATA_BYCH_RAW.exists():
        ch = pd.read_csv(DATA_BYCH_RAW, parse_dates=["date"])
        mask(ch, rng, factors, amount_k).to_csv(DATA_BYCH_MASKED, index=False, encoding="utf-8-sig")
    print(f"Готово: {DATA_MASKED.name}" + (f", {DATA_BYCH_MASKED.name}" if DATA_BYCH_RAW.exists() else ""))


if __name__ == "__main__":
    main()
