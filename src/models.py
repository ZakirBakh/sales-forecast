"""Модели прогноза: два наивных бейзлайна и четыре ML-модели.

Все ML-модели — «глобальные»: одна модель обучается сразу на всех 15 рядах.
Ряд передаётся как категориальный признак. Плюсы такого подхода:
  * у маленьких рядов мало данных — глобальная модель переносит на них
    общие закономерности (день недели, праздники, эффект после выходных);
  * одна модель вместо 15 — проще поддерживать.

Целевая переменная у Ridge / RandomForest / CatBoost — log1p(y): продажи
отличаются между рядами в сотни раз, логарифм выравнивает масштаб и
стабилизирует обучение. LightGBM обучается сразу на y с функцией потерь
Tweedie, которая подходит для неотрицательных счётных данных с нулями.
"""
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import RandomForestRegressor
from sklearn.impute import SimpleImputer
from sklearn.linear_model import Ridge
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

from .config import RANDOM_STATE
from .features import CAT_FEATURES

# ---------------------------------------------------------------- бейзлайны
def baseline_naive_28(df: pd.DataFrame) -> np.ndarray:
    """Сезонный наивный прогноз: «как 4 недели назад в тот же день недели»."""
    return df["lag_28"].fillna(0).values


def baseline_same_dow_4w(df: pd.DataFrame) -> np.ndarray:
    """Среднее по тому же дню недели за 4 последние известные недели.
    Более устойчивый бейзлайн: сглаживает разовые всплески."""
    return df["same_dow_mean_4"].fillna(0).values


# --------------------------------------------------------------- ML-модели
def _num_cols(cols):
    return [c for c in cols if c not in CAT_FEATURES]


class RidgeModel:
    """Линейная регрессия с L2-регуляризацией.

    Линейной модели самой не «догадаться», что недельный профиль у каждого
    ряда свой, поэтому добавляем признак-взаимодействие «ряд × день недели».
    Числовые признаки уровня логарифмируем и стандартизируем, пропуски
    (например, lag_364 в первый год) заполняем медианой.
    """
    def __init__(self, alpha=1.0):
        self.alpha = alpha

    def _prep(self, X):
        X = X.copy()
        X["series_dow"] = X["series"].astype(str) + "_" + X["dow"].astype(str)
        for c in _num_cols(self.cols):
            if c.startswith(("lag_", "roll_", "same_dow", "workday", "yoy")):
                X[c] = np.log1p(X[c].clip(lower=0))
        return X

    def fit(self, X, y):
        self.cols = list(X.columns)
        cat = CAT_FEATURES + ["series_dow", "dow", "month"]
        num = [c for c in _num_cols(self.cols) if c not in ("dow", "month")]
        pre = ColumnTransformer([
            ("cat", OneHotEncoder(handle_unknown="ignore"), cat),
            ("num", Pipeline([("imp", SimpleImputer(strategy="median")), ("sc", StandardScaler())]), num),
        ])
        self.pipe = Pipeline([("pre", pre), ("reg", Ridge(alpha=self.alpha))])
        self.pipe.fit(self._prep(X), np.log1p(y))
        return self

    def predict(self, X):
        return np.clip(np.expm1(self.pipe.predict(self._prep(X))), 0, None)


class RFModel:
    """Случайный лес: ансамбль деревьев на бутстрэп-выборках.
    Категориальные признаки кодируем числами, пропуски заменяем на −1."""
    def __init__(self, **params):
        self.params = {"n_estimators": 300, "min_samples_leaf": 5, "max_features": 0.5,
                       "n_jobs": -1, "random_state": RANDOM_STATE, **params}

    def _prep(self, X):
        X = X.copy()
        for c in CAT_FEATURES:
            X[c] = X[c].cat.codes
        return X.fillna(-1)

    def fit(self, X, y):
        self.model = RandomForestRegressor(**self.params).fit(self._prep(X), np.log1p(y))
        return self

    def predict(self, X):
        return np.clip(np.expm1(self.model.predict(self._prep(X))), 0, None)


LGBM_DEFAULT = {"objective": "tweedie", "tweedie_variance_power": 1.3, "learning_rate": 0.05,
                "num_leaves": 31, "min_child_samples": 20, "feature_fraction": 0.8,
                "bagging_fraction": 0.8, "bagging_freq": 1, "lambda_l2": 1.0,
                "n_estimators": 600, "verbose": -1, "random_state": RANDOM_STATE}


class LGBMModel:
    """Градиентный бустинг LightGBM: деревья строятся последовательно, каждое
    следующее исправляет ошибки предыдущих. Категории (ряд, группа) LightGBM
    обрабатывает сам. Функция потерь Tweedie — для счётных данных с нулями."""
    def __init__(self, **params):
        self.params = {**LGBM_DEFAULT, **params}

    def fit(self, X, y):
        import lightgbm as lgb
        p = dict(self.params)
        n = p.pop("n_estimators")
        self.model = lgb.LGBMRegressor(n_estimators=n, **p).fit(X, y, categorical_feature=CAT_FEATURES)
        return self

    def predict(self, X):
        return np.clip(self.model.predict(X), 0, None)

    def feature_importance(self) -> pd.Series:
        b = self.model.booster_
        return pd.Series(b.feature_importance("gain"), index=b.feature_name()).sort_values(ascending=False)


class CatBoostModel:
    """Градиентный бустинг CatBoost: симметричные деревья и встроенная работа
    с категориальными признаками (target statistics без утечки)."""
    def __init__(self, **params):
        self.params = {"iterations": 800, "learning_rate": 0.05, "depth": 6, "l2_leaf_reg": 3,
                       "loss_function": "RMSE", "random_seed": RANDOM_STATE, "verbose": 0,
                       "thread_count": -1, "allow_writing_files": False, **params}

    def _prep(self, X):
        X = X.copy()
        for c in CAT_FEATURES:
            X[c] = X[c].astype(str)
        return X

    def fit(self, X, y):
        from catboost import CatBoostRegressor
        self.model = CatBoostRegressor(**self.params, cat_features=CAT_FEATURES)
        self.model.fit(self._prep(X), np.log1p(y))
        return self

    def predict(self, X):
        return np.clip(np.expm1(self.model.predict(self._prep(X))), 0, None)


MODELS = {"Ridge": RidgeModel, "RandomForest": RFModel, "LightGBM": LGBMModel, "CatBoost": CatBoostModel}
