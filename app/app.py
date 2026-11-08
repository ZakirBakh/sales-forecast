"""Демо: прогноз продаж банковских продуктов на 4 недели вперёд.

Запуск из корня проекта:
    streamlit run app/app.py

Что умеет:
  * выбрать группу продуктов и ряд — увидеть историю и прогноз на 7–28 дней;
  * сценарий «ограничение выдач кредитов» — как изменится прогноз, если банк
    снова ограничит выдачи (признак credit_supply_limit = 1);
  * посмотреть, насколько модель точна на тестовом периоде по сравнению с бейзлайном;
  * скачать прогноз в CSV.
"""
import json
import sys
from pathlib import Path
import joblib
import numpy as np
import pandas as pd
import plotly.graph_objects as go
import streamlit as st

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from src import config as C                                   # noqa: E402
from src.data import add_feature_target, load_series          # noqa: E402
from src.features import add_future, build_features           # noqa: E402
from src.metrics import wape                                  # noqa: E402

st.set_page_config(page_title="Прогноз продаж", page_icon="📈", layout="wide")
COL = {"fact": "#0b0b0b", "model": "#eb6834", "base": "#2a78d6", "band": "rgba(42,120,214,0.08)"}


# ------------------------------------------------------------------ загрузка
def data_path() -> Path:
    """Реальные данные, если они есть локально; иначе — обезличенная версия."""
    return C.DATA


@st.cache_resource
def load_model():
    bundle = joblib.load(C.MODELS / "final_model.pkl")
    meta = json.loads((C.MODELS / "metadata.json").read_text(encoding="utf-8"))
    return bundle["model"], bundle["columns"], meta


@st.cache_data
def load_history():
    return add_feature_target(load_series(data_path()), C.ONE_OFF_EVENTS)


@st.cache_data
def make_forecast(credit_limit: int) -> pd.DataFrame:
    """Прогноз на HORIZON дней после последней даты в данных (для всех рядов)."""
    model, cols, _ = load_model()
    fut = build_features(add_future(load_history(), C.HORIZON, credit_limit))
    fut = fut[fut["y"].isna()]
    out = fut[["date", "product_group", "series"]].copy()
    out["forecast"] = model.predict(fut[cols])
    return out


@st.cache_data
def load_test_predictions():
    p = C.REPORTS / "predictions_test.csv"
    return pd.read_csv(p, parse_dates=["date"]) if p.exists() else None


def short(s: str) -> str:
    return s.split(": ", 1)[1]


# ------------------------------------------------------------------ интерфейс
model, cols, meta = load_model()
hist = load_history()

st.title("📈 Прогноз продаж розничных продуктов банка")
st.caption(f"Модель: LightGBM (Optuna), глобальная для {len(meta['series'])} рядов · "
           f"данные до {meta['data_last_date']} · горизонт {meta['horizon_days']} дней · "
           f"источник: {'реальные данные' if data_path() == C.DATA_RAW else 'обезличенные данные'}")

with st.sidebar:
    st.header("Параметры")
    group = st.selectbox("Группа продуктов", ["Карта", "Кредит", "Депозит"])
    options = sorted(hist.loc[hist["product_group"] == group, "series"].unique(), key=short)
    choice = st.selectbox("Ряд", ["Все продукты группы"] + [short(s) for s in options])
    horizon = st.slider("Горизонт прогноза, дней", 7, C.HORIZON, C.HORIZON, step=7)
    freq = st.radio("Детализация графика", ["по дням", "по неделям"], horizontal=True)
    limit = st.toggle("Сценарий: ограничение выдач кредитов", value=False,
                      help="Как в 10.2023–02.2024: банк ограничивает выдачи из-за нехватки ресурсов. "
                           "Влияет только на кредиты.", disabled=(group != "Кредит"))
    st.divider()
    st.markdown("**Как читать прогноз**\n\nМодель использует продажи до дня *t − 28* и календарь "
                "(выходные, праздники КР, длинные каникулы). О будущих акциях и массовых выпусках "
                "карт она не знает — такие события нужно добавлять вручную.")

sel = options if choice == "Все продукты группы" else [f"{group}: {choice}"]
fc_all = make_forecast(int(limit and group == "Кредит"))
fc = fc_all[fc_all["series"].isin(sel)]
fc = fc[fc["date"] <= fc["date"].min() + pd.Timedelta(days=horizon - 1)]
h = hist[hist["series"].isin(sel)]

fc_day = fc.groupby("date")["forecast"].sum()
h_day = h.groupby("date")["y"].sum()
last_n = h_day.iloc[-horizon:]
year_ago = h_day.reindex(fc_day.index - pd.Timedelta(days=364))

# ---- ключевые цифры
c1, c2, c3, c4 = st.columns(4)
c1.metric(f"Прогноз на {horizon} дн.", f"{fc_day.sum():,.0f}".replace(",", " "))
c2.metric(f"Факт за последние {horizon} дн.", f"{last_n.sum():,.0f}".replace(",", " "),
          delta=f"{(fc_day.sum() / max(last_n.sum(), 1) - 1) * 100:+.0f} % прогноз к факту", delta_color="off")
if year_ago.notna().all() and year_ago.sum() > 0:
    c3.metric("Те же дни год назад", f"{year_ago.sum():,.0f}".replace(",", " "),
              delta=f"{(fc_day.sum() / year_ago.sum() - 1) * 100:+.0f} % г/г", delta_color="off")
else:
    c3.metric("Те же дни год назад", "нет данных")
test = load_test_predictions()
if test is not None:
    t = test[test["series"].isin(sel)]
    c4.metric("Точность на тесте (WAPE)", f"{wape(t['y'], t['LightGBM_tuned']):.2f}",
              delta=f"бейзлайн {wape(t['y'], t['same_dow_4w']):.2f}", delta_color="off",
              help="WAPE = Σ|факт − прогноз| / Σ факт на июле–сентябре 2026 г. Меньше — лучше.")

tab1, tab2, tab3 = st.tabs(["Прогноз", "Качество на тесте", "О модели"])

# ---- вкладка 1: история + прогноз
with tab1:
    hist_win = h_day[h_day.index > h_day.index.max() - pd.Timedelta(days=120)]
    hs, fs = hist_win, fc_day
    if freq == "по неделям":
        hs = hist_win.resample("W").sum().iloc[1:-1]   # без неполных крайних недель
        fs = fc_day.resample("W").sum()
    fig = go.Figure()
    fig.add_trace(go.Scatter(x=hs.index, y=hs.values, name="факт", line=dict(color=COL["fact"], width=1.6),
                             hovertemplate="%{x|%d.%m.%Y}<br>факт: %{y:,.0f}<extra></extra>"))
    fig.add_trace(go.Scatter(x=fs.index, y=fs.values, name="прогноз", line=dict(color=COL["model"], width=2.2),
                             hovertemplate="%{x|%d.%m.%Y}<br>прогноз: %{y:,.0f}<extra></extra>"))
    fig.add_vrect(x0=fs.index.min(), x1=fs.index.max(), fillcolor=COL["band"], line_width=0)
    fig.update_layout(height=420, margin=dict(l=10, r=10, t=30, b=10), hovermode="x unified",
                      plot_bgcolor="#fcfcfb", paper_bgcolor="#fcfcfb", legend=dict(orientation="h", y=1.08),
                      yaxis=dict(rangemode="tozero", gridcolor="#e4e3df"), xaxis=dict(gridcolor="#e4e3df"))
    st.plotly_chart(fig, width="stretch")
    for s, a, b, desc in C.ONE_OFF_EVENTS:
        if s in sel:
            st.info(f"В истории есть разовое событие ({short(s)}, {a} – {b}): {desc}. "
                    "Для прогноза оно убрано из лагов модели, поэтому сравнение «прогноз к факту» "
                    "за последние дни занижено.")

    if len(sel) > 1:
        st.subheader("Прогноз по продуктам группы")
        tab = fc.groupby("series")["forecast"].sum().rename("прогноз").to_frame()
        tab["факт за последние дни"] = h[h["date"] > h["date"].max() - pd.Timedelta(days=horizon)].groupby("series")["y"].sum()
        tab["изменение, %"] = ((tab["прогноз"] / tab["факт за последние дни"].clip(lower=1) - 1) * 100).round(0)
        tab.index = [short(s) for s in tab.index]
        st.dataframe(tab.sort_values("прогноз", ascending=False).style.format({"прогноз": "{:,.0f}", "факт за последние дни": "{:,.0f}", "изменение, %": "{:+.0f}"}),
                     width="stretch")

    out = fc.assign(series=fc["series"].map(short)).rename(columns={"forecast": "прогноз"})
    out["прогноз"] = out["прогноз"].round(1)
    st.download_button("⬇️ Скачать прогноз (CSV)", out.to_csv(index=False).encode("utf-8-sig"),
                       file_name="forecast.csv", mime="text/csv")

# ---- вкладка 2: качество на тесте
with tab2:
    if test is None:
        st.info("Нет файла reports/predictions_test.csv — запустите `python -m src.pipeline`.")
    else:
        t = test[test["series"].isin(sel)].groupby("date")[["y", "LightGBM_tuned", "same_dow_4w"]].sum()
        fig2 = go.Figure()
        for c, name, color, dash in [("y", "факт", COL["fact"], None), ("LightGBM_tuned", "модель", COL["model"], None),
                                     ("same_dow_4w", "бейзлайн (тот же день недели, 4 нед.)", COL["base"], "dash")]:
            fig2.add_trace(go.Scatter(x=t.index, y=t[c], name=name, line=dict(color=color, width=1.6, dash=dash)))
        fig2.update_layout(height=380, margin=dict(l=10, r=10, t=30, b=10), hovermode="x unified",
                           plot_bgcolor="#fcfcfb", paper_bgcolor="#fcfcfb", legend=dict(orientation="h", y=1.1),
                           yaxis=dict(rangemode="tozero", gridcolor="#e4e3df"))
        st.plotly_chart(fig2, width="stretch")
        st.caption("Тест — июль–сентябрь 2026 г.: модель обучена на данных до 30.06.2026 и прогнозирует каждый "
                   "день по данным, известным за 28 дней до него.")
        rows = []
        for s in sel:
            g = test[test["series"] == s]
            rows.append({"ряд": short(s), "факт": g["y"].sum(), "WAPE модели": wape(g["y"], g["LightGBM_tuned"]),
                         "WAPE бейзлайна": wape(g["y"], g["same_dow_4w"])})
        st.dataframe(pd.DataFrame(rows).set_index("ряд").style.format({"факт": "{:,.0f}", "WAPE модели": "{:.2f}", "WAPE бейзлайна": "{:.2f}"}),
                     width="stretch")

# ---- вкладка 3: о модели
with tab3:
    m, b = meta["test_metrics_without_events"], meta["test_metrics_without_events_baseline"]
    st.markdown(f"""
**Задача:** прогноз числа продаж (новых договоров) на каждый из 28 следующих дней по {len(meta['series'])} рядам.

**Модель:** одна глобальная модель LightGBM на все ряды, {meta['n_features']} признаков — лаги 28–364 дня,
средние по тому же дню недели, тренд, календарь праздников КР, длинные выходные, ограничение выдач кредитов.
Гиперпараметры подобраны в Optuna ({meta['optuna_trials']} итераций) по WAPE на валидации (апрель–июнь 2026).

**Качество на тесте (июль–сентябрь 2026, без разового выпуска карт нерезидентам):**

| | модель | бейзлайн |
|---|---|---|
| WAPE по дням | {m['WAPE']:.3f} | {b['WAPE']:.3f} |
| WAPE по неделям | {m['WAPE_week']:.3f} | {b['WAPE_week']:.3f} |
| WAPE по месяцам | {m['WAPE_month']:.3f} | {b['WAPE_month']:.3f} |

Скользящий бэктест (13 прогнозов по 28 дней): средний WAPE модели **{meta['backtest_mean_WAPE']['model']:.3f}**
против **{meta['backtest_mean_WAPE']['baseline']:.3f}** у бейзлайна.

**Ограничения:** модель не знает о будущих акциях и массовых выпусках карт; на горизонте месяца её выигрыш у
бейзлайна пропадает; ряды, которые движутся кампаниями (нерезиденты, Элкарт пенс/соц, зарплатные), прогнозируются хуже всего.
""")
