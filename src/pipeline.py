"""Полный воспроизводимый пайплайн: данные → признаки → модели → оценка → артефакты.

Запуск из корня проекта:
    python -m src.pipeline                # всё целиком (около 10–15 минут)
    python -m src.pipeline --trials 20    # меньше итераций Optuna, быстрее

Результаты:
    reports/metrics_validation.csv   — сравнение моделей на валидации
    reports/metrics_test.csv         — финальная оценка на тесте
    reports/metrics_test_by_series.csv
    reports/predictions_test.csv     — факт и прогнозы всех моделей на тесте
    reports/optuna_trials.csv        — история подбора гиперпараметров
    models/final_model.pkl           — итоговая модель, обученная на всех данных
    models/metadata.json             — параметры, метрики, даты
    data/processed/forecast_next28.csv — прогноз на 28 дней после последней даты
"""
import argparse
import json
import time

import joblib
import numpy as np
import pandas as pd

from . import config as C
from .data import add_feature_target, load_series
from .features import add_future, build_features, feature_columns, usable_rows
from .metrics import per_series, summary, wape
from .models import MODELS, LGBM_DEFAULT, LGBMModel, baseline_naive_28, baseline_same_dow_4w


# ------------------------------------------------------------------ данные
def make_dataset(path=C.DATA):
    df = add_feature_target(load_series(path), C.ONE_OFF_EVENTS)
    feats = build_features(df)
    feats = feats[usable_rows(feats)].reset_index(drop=True)
    return df, feats


def split(feats: pd.DataFrame):
    """Разбиение строго по времени. Дни ограничения выдач кредитов не используем
    для оценки (это не спрос), но оставляем в обучении — модель видит флаг."""
    tr = feats[feats["date"] <= C.TRAIN_END]
    va = feats[(feats["date"] >= C.VAL_START) & (feats["date"] <= C.VAL_END)]
    te = feats[(feats["date"] >= C.TEST_START) & (feats["date"] <= C.TEST_END)]
    return tr, va, te


def event_mask(df: pd.DataFrame) -> pd.Series:
    """True для строк, НЕ попадающих в известные разовые события."""
    m = pd.Series(True, index=df.index)
    for s, a, b, _ in C.ONE_OFF_EVENTS:
        m &= ~((df["series"] == s) & df["date"].between(a, b))
    return m


def fit_predict(name, params, train, pred_df, cols):
    """Обучает модель и прогнозирует pred_df.
    Дни известных разовых событий (ONE_OFF_EVENTS), если они попали в обучение,
    из обучения убираются: это не повторяющийся спрос, и без этого модель после
    события завышает прогноз ряда (видно в бэктесте). Из оценки они не убираются."""
    train = train[event_mask(train)]
    model = MODELS[name](**params).fit(train[cols], train["y"].values)
    return model, model.predict(pred_df[cols])


# ------------------------------------------------------------------ Optuna
def tune_lgbm(train, val, cols, n_trials=40):
    """Подбор гиперпараметров LightGBM по WAPE на валидации (TPE-сэмплер Optuna)."""
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    def objective(trial):
        params = {
            "objective": trial.suggest_categorical("objective", ["tweedie", "poisson", "regression_l1"]),
            "learning_rate": trial.suggest_float("learning_rate", 0.01, 0.15, log=True),
            "num_leaves": trial.suggest_int("num_leaves", 8, 128, log=True),
            "min_child_samples": trial.suggest_int("min_child_samples", 5, 100, log=True),
            "feature_fraction": trial.suggest_float("feature_fraction", 0.4, 1.0),
            "bagging_fraction": trial.suggest_float("bagging_fraction", 0.5, 1.0),
            "lambda_l2": trial.suggest_float("lambda_l2", 1e-3, 30, log=True),
            "n_estimators": trial.suggest_int("n_estimators", 200, 1500, step=100),
        }
        if params["objective"] == "tweedie":
            params["tweedie_variance_power"] = trial.suggest_float("tweedie_variance_power", 1.05, 1.8)
        _, p = fit_predict("LightGBM", params, train, val, cols)
        return wape(val["y"], p)

    study = optuna.create_study(direction="minimize",
                                sampler=optuna.samplers.TPESampler(seed=C.RANDOM_STATE))
    study.optimize(objective, n_trials=n_trials, show_progress_bar=False)
    return study


# ------------------------------------------------------------------ события и бэктест
def backtest(feats, cols, params, start="2025-10-02", end=C.TEST_END, step=C.HORIZON):
    """Скользящий бэктест: в каждой точке отсчёта модель обучается на всём,
    что было ДО неё, и прогнозирует следующие 28 дней. Ровно так модель
    будет работать в жизни (раз в 4 недели переобучение и прогноз)."""
    rows, preds = [], []
    origins = pd.date_range(start, end, freq=f"{step}D")
    for o in origins:
        stop = min(o + pd.Timedelta(days=step - 1), pd.Timestamp(end))
        train = feats[feats["date"] < o]
        win = feats[(feats["date"] >= o) & (feats["date"] <= stop)]
        if win.empty:
            continue
        _, p = fit_predict("LightGBM", params, train, win, cols)
        out = win[["date", "product_group", "series", "y"]].copy()
        out["LightGBM_tuned"] = p
        out["same_dow_4w"] = baseline_same_dow_4w(win)
        out["origin"] = o
        preds.append(out)
        rows.append({"origin": o.date(), "end": stop.date(),
                     "WAPE_model": wape(out["y"], out["LightGBM_tuned"]),
                     "WAPE_baseline": wape(out["y"], out["same_dow_4w"])})
    return pd.DataFrame(rows), pd.concat(preds, ignore_index=True)


# ------------------------------------------------------------------ полный прогон
def run(n_trials=40, path=C.DATA, verbose=True):
    t0 = time.time()
    log = (lambda *a: print(*a, flush=True)) if verbose else (lambda *a: None)
    C.REPORTS.mkdir(exist_ok=True); C.MODELS.mkdir(exist_ok=True); C.DATA_PROCESSED.mkdir(exist_ok=True)

    df, feats = make_dataset(path)
    cols = feature_columns(feats)
    tr, va, te = split(feats)
    log(f"Строк: train={len(tr)}, val={len(va)}, test={len(te)}; признаков: {len(cols)}")

    # 1. Валидация: все модели с параметрами по умолчанию
    val = va[["date", "product_group", "series", "y"]].copy()
    val["naive_28"] = baseline_naive_28(va)
    val["same_dow_4w"] = baseline_same_dow_4w(va)
    for name in MODELS:
        _, val[name] = fit_predict(name, {}, tr, va, cols)
        log(f"  {name}: val WAPE = {wape(val['y'], val[name]):.3f}")

    # 2. Подбор гиперпараметров LightGBM
    study = tune_lgbm(tr, va, cols, n_trials)
    best = study.best_params
    _, val["LightGBM_tuned"] = fit_predict("LightGBM", best, tr, va, cols)
    log(f"  LightGBM_tuned: val WAPE = {wape(val['y'], val['LightGBM_tuned']):.3f}  ({n_trials} итераций)")
    study.trials_dataframe().to_csv(C.REPORTS / "optuna_trials.csv", index=False)
    m_val = summary(val, ["naive_28", "same_dow_4w", *MODELS, "LightGBM_tuned"])
    m_val.to_csv(C.REPORTS / "metrics_validation.csv")

    # 3. Тест: переобучаем на train + val и прогнозируем тест (один раз)
    trva = pd.concat([tr, va])
    test = te[["date", "product_group", "series", "y"]].copy()
    test["naive_28"] = baseline_naive_28(te)
    test["same_dow_4w"] = baseline_same_dow_4w(te)
    for name in MODELS:
        _, test[name] = fit_predict(name, {}, trva, te, cols)
    tuned, test["LightGBM_tuned"] = fit_predict("LightGBM", best, trva, te, cols)
    m_test = summary(test, ["naive_28", "same_dow_4w", *MODELS, "LightGBM_tuned"])
    m_test.to_csv(C.REPORTS / "metrics_test.csv")
    m_test_clean = summary(test[event_mask(test)], ["naive_28", "same_dow_4w", *MODELS, "LightGBM_tuned"])
    m_test_clean.to_csv(C.REPORTS / "metrics_test_without_events.csv")
    per_series(test, "LightGBM_tuned").to_csv(C.REPORTS / "metrics_test_by_series.csv")
    test.to_csv(C.REPORTS / "predictions_test.csv", index=False)
    tuned.feature_importance().to_csv(C.REPORTS / "feature_importance.csv", header=["gain"])
    log(m_test.round(3).to_string())

    # 4. Скользящий бэктест (13 окон по 28 дней) — насколько стабилен выигрыш
    bt, bt_pred = backtest(feats, cols, best)
    bt.to_csv(C.REPORTS / "backtest_folds.csv", index=False)
    bt_pred.to_csv(C.REPORTS / "backtest_predictions.csv", index=False)
    log(bt.round(3).to_string())

    # 5. Итоговая модель на всех данных + прогноз на 28 дней вперёд
    clean = feats[event_mask(feats)]
    final = LGBMModel(**best).fit(clean[cols], clean["y"].values)
    future = build_features(add_future(df))
    future = future[future["y"].isna()]
    fc = future[["date", "product_group", "series"]].copy()
    fc["forecast"] = final.predict(future[cols])
    fc.to_csv(C.DATA_PROCESSED / "forecast_next28.csv", index=False)
    joblib.dump({"model": final, "columns": cols}, C.MODELS / "final_model.pkl")

    meta = {
        "created": pd.Timestamp.now().isoformat(timespec="seconds"),
        "data_last_date": str(df["date"].max().date()),
        "horizon_days": C.HORIZON,
        "split": {"train_end": C.TRAIN_END, "val": [C.VAL_START, C.VAL_END], "test": [C.TEST_START, C.TEST_END]},
        "best_params": {**LGBM_DEFAULT, **best},
        "optuna_trials": n_trials,
        "test_metrics": m_test.loc["LightGBM_tuned"].round(4).to_dict(),
        "test_metrics_baseline": m_test.loc["same_dow_4w"].round(4).to_dict(),
        "test_metrics_without_events": m_test_clean.loc["LightGBM_tuned"].round(4).to_dict(),
        "test_metrics_without_events_baseline": m_test_clean.loc["same_dow_4w"].round(4).to_dict(),
        "backtest_mean_WAPE": {"model": round(bt["WAPE_model"].mean(), 4), "baseline": round(bt["WAPE_baseline"].mean(), 4)},
        "n_features": len(cols), "features": cols,
        "series": sorted(df["series"].unique().tolist()),
    }
    (C.MODELS / "metadata.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    log(f"Готово за {time.time() - t0:.0f} c")
    return {"val": val, "test": test, "m_val": m_val, "m_test": m_test, "m_test_clean": m_test_clean,
            "study": study, "backtest": bt, "backtest_pred": bt_pred, "meta": meta, "final": final}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--trials", type=int, default=40)
    ap.add_argument("--data", default=str(C.DATA))
    a = ap.parse_args()
    run(n_trials=a.trials, path=a.data)
