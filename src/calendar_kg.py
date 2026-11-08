"""Производственный календарь Кыргызстана для признаков модели.

Источник — библиотека `holidays` (праздники и перенесённые выходные КР).
Список проверен по данным: в каждый праздничный будний день продажи банка
падают почти до нуля. Кроме того, по данным найдено 5 нерабочих дней банка,
которых нет в библиотеке, — они добавлены вручную (EXTRA_DAYS_OFF).
"""
import holidays
import pandas as pd

# Будние дни, когда продаж почти не было, хотя официального праздника нет
# (найдены в EDA: продажи < 35 % от обычного уровня).
EXTRA_DAYS_OFF = ["2024-11-19", "2024-11-20", "2026-01-08", "2026-01-09", "2026-09-01"]


def days_off(start="2022-01-01", end="2027-12-31") -> set:
    """Множество праздничных / нерабочих дат (без обычных выходных)."""
    years = range(pd.Timestamp(start).year, pd.Timestamp(end).year + 1)
    kg = holidays.country_holidays("KG", years=years)
    out = {pd.Timestamp(d) for d in kg.keys()}
    out |= {pd.Timestamp(d) for d in EXTRA_DAYS_OFF}
    return out


def calendar_features(dates: pd.Series) -> pd.DataFrame:
    """Календарные признаки для каждой даты.

    Все они известны заранее, поэтому могут использоваться для прогноза
    без утечки данных.
    """
    d = pd.to_datetime(dates)
    off = days_off()
    is_holiday = d.isin(off)
    is_weekend = d.dt.dayofweek >= 5
    nonwork = is_holiday | is_weekend

    # Сколько нерабочих дней было подряд перед датой: после длинных выходных
    # в первый рабочий день продаж больше (накопленный спрос).
    all_days = pd.date_range(d.min() - pd.Timedelta(days=15), d.max() + pd.Timedelta(days=15))
    nw = pd.Series([(x in off) or (x.dayofweek >= 5) for x in all_days], index=all_days)
    run = []
    cnt = 0
    for x in all_days:
        run.append(cnt)
        cnt = cnt + 1 if nw[x] else 0
    nonwork_before = pd.Series(run, index=all_days)   # нерабочих дней подряд ДО даты
    next_nonwork = nw.shift(-1).fillna(False)          # завтра выходной / праздник

    return pd.DataFrame({
        "dow": d.dt.dayofweek.values,                 # день недели 0=пн … 6=вс
        "dom": d.dt.day.values,                       # день месяца (зарплатные дни)
        "month": d.dt.month.values,
        "weekofyear": d.dt.isocalendar().week.astype(int).values,
        "days_to_month_end": (d.dt.days_in_month - d.dt.day).values,
        "is_holiday": is_holiday.astype(int).values,
        "is_nonwork": nonwork.astype(int).values,
        "nonwork_before": nonwork_before.reindex(d).values,
        "pre_nonwork": next_nonwork.reindex(d).astype(int).values,
    }, index=dates.index)
