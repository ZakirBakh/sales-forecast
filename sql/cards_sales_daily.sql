/* =====================================================================
   Продажи карт по дням — проект «Прогноз продаж»
   MS SQL Server
   ---------------------------------------------------------------------
   Витрина: DateABS = последний день месяца, срез = карты в обороте за месяц.
   Каждая карта берётся из среза месяца открытия: DateABS = EOMONTH(OpenDate).
   Продажа = новый карточный договор (CardAccountNo).
   Исключены карты сотрудников (CardId = NULL, счёт = ***).

   281 продукт -> признаки (ПС, уровень, зарплатная, кредитная) -> 6 рядов.

   ПОРЯДОК ЗАПУСКА: 1 -> 2 (проверить и поправить правила) -> 3 -> 4 -> 5
   ===================================================================== */


/* =====================================================================
   1. КЛАССИФИКАЦИЯ ПРОДУКТОВ по названию (регистр не важен)
   ===================================================================== */
IF OBJECT_ID('tempdb..#product_class') IS NOT NULL DROP TABLE #product_class;

WITH products AS (
    SELECT ProductID,
           MAX(ProductName)                AS ProductName,
           LOWER(MAX(ProductName))         AS pn          -- нижний регистр для поиска
    FROM DWH.dbo.vw_Cards
    WHERE OpenDate >= '2023-01-01'
      AND DateABS  >= '2023-01-31'
      AND BusinessType = N'Розничный бизнес'
      AND ProductID IS NOT NULL
    GROUP BY ProductID
),
attrs AS (
    SELECT
        ProductID, ProductName, pn,

        -- Платёжная система (+ сколько систем найдено: >1 = кобейдж или ошибка правил)
        CASE
            WHEN pn LIKE N'%элкарт%' OR pn LIKE N'%elcart%' OR pn LIKE N'%el cart%'  THEN N'Элкарт'
            WHEN pn LIKE N'%visa%'   OR pn LIKE N'%виза%'                            THEN N'Visa'
            WHEN pn LIKE N'%master%' OR pn LIKE N'%мастер%'                          THEN N'MasterCard'
            ELSE N'НЕ ОПРЕДЕЛЕНО'
        END AS pay_system,
          CASE WHEN pn LIKE N'%элкарт%' OR pn LIKE N'%elcart%' OR pn LIKE N'%el cart%' THEN 1 ELSE 0 END
        + CASE WHEN pn LIKE N'%visa%'   OR pn LIKE N'%виза%'   THEN 1 ELSE 0 END
        + CASE WHEN pn LIKE N'%master%' OR pn LIKE N'%мастер%' THEN 1 ELSE 0 END
          AS pay_system_matches,

        -- Уровень / разновидность карты
        CASE
            -- Элкарт
            WHEN pn LIKE N'%пенси%'                                   THEN N'Пенсионная'
            WHEN pn LIKE N'%социал%'                                  THEN N'Социальная'
            WHEN pn LIKE N'%элкарт+%' OR pn LIKE N'%элкарт +%'
              OR pn LIKE N'%elcart+%' OR pn LIKE N'%elcart +%'
              OR pn LIKE N'%плюс%'    OR pn LIKE N'%plus%'            THEN N'Элкарт+'
            -- Visa / MasterCard
            WHEN pn LIKE N'%infinit%'  OR pn LIKE N'%инфинит%'        THEN N'Infinite'
            WHEN pn LIKE N'%world elite%' OR pn LIKE N'%elite%'
              OR pn LIKE N'%элит%'                                    THEN N'World Elite'
            WHEN pn LIKE N'%platinum%' OR pn LIKE N'%платин%'         THEN N'Platinum'
            WHEN pn LIKE N'%gold%'     OR pn LIKE N'%голд%'
              OR pn LIKE N'%золот%'                                   THEN N'Gold'
            WHEN pn LIKE N'%classic%'  OR pn LIKE N'%классик%'        THEN N'Classic'
            ELSE N'Базовая / прочая'
        END AS card_tier,

        CASE WHEN pn LIKE N'%зарплат%' OR pn LIKE N'%зп %' OR pn LIKE N'% зп%'
               OR pn LIKE N'%salary%' OR pn LIKE N'%payroll%'
             THEN 1 ELSE 0 END AS is_salary,

        CASE WHEN pn LIKE N'%кредит%' OR pn LIKE N'%credit%'
             THEN 1 ELSE 0 END AS is_credit
    FROM products
)
SELECT
    a.*,
    CASE
        WHEN a.is_credit = 1                                      THEN N'Кредитные'
        WHEN a.card_tier IN (N'Пенсионная', N'Социальная')        THEN N'Элкарт пенс/соц'
        WHEN a.is_salary = 1                                      THEN N'Зарплатные'
        WHEN a.pay_system = N'Visa'                               THEN N'Visa розница'
        WHEN a.pay_system = N'MasterCard'                         THEN N'MasterCard розница'
        WHEN a.pay_system = N'Элкарт'                             THEN N'Элкарт розница'
        ELSE N'Прочие'
    END AS forecast_series
INTO #product_class
FROM attrs a;


/* =====================================================================
   2. ПРОВЕРКА КЛАССИФИКАЦИИ — обязательно просмотреть глазами
   ===================================================================== */

-- 2.1 Что не распозналось или распозналось двусмысленно
SELECT ProductID, ProductName, pay_system, pay_system_matches,
       card_tier, is_salary, is_credit, forecast_series
FROM #product_class
WHERE pay_system = N'НЕ ОПРЕДЕЛЕНО'
   OR pay_system_matches > 1                 -- кобейдж (напр. Элкарт-Visa) или ложное срабатывание
   OR forecast_series = N'Прочие'
ORDER BY ProductName;

-- 2.2 Выборочно проверить срабатывания «кредит» и «зарплат»:
-- слово «кредит» может встретиться и в названии дебетовой карты
SELECT ProductID, ProductName, is_credit, is_salary, forecast_series
FROM #product_class
WHERE is_credit = 1 OR is_salary = 1
ORDER BY forecast_series, ProductName;

-- 2.3 Объём продаж по итоговым рядам и признакам:
-- ряд со средним < ~10 продаж в день лучше объединить с соседним
WITH cards AS (
    SELECT DISTINCT v.CardAccountNo, v.ProductID, CAST(v.OpenDate AS date) AS OpenDate
    FROM DWH.dbo.vw_Cards v
    WHERE v.DateABS = EOMONTH(v.OpenDate)
      AND v.DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND v.OpenDate >= '2023-01-01'
      AND v.BalanceCardAccountNo <> '00000' /* код балансового счёта-исключения */
      AND v.BusinessType = N'Розничный бизнес'
      AND v.CardId IS NOT NULL
      AND v.CardAccountNo NOT LIKE '%***%'
)
SELECT
    pc.forecast_series, pc.pay_system, pc.card_tier,
    COUNT(DISTINCT pc.ProductID)                       AS products,
    COUNT(DISTINCT c.CardAccountNo)                    AS contracts_total,
    COUNT(DISTINCT c.CardAccountNo) * 1.0
      / NULLIF(DATEDIFF(day, '2023-01-01', EOMONTH(GETDATE(), -1)) + 1, 0)
                                                       AS avg_sales_per_day
FROM cards c
JOIN #product_class pc ON pc.ProductID = c.ProductID
GROUP BY ROLLUP (pc.forecast_series, pc.pay_system, pc.card_tier)
ORDER BY pc.forecast_series, pc.pay_system, pc.card_tier;


/* =====================================================================
   3. ОСНОВНАЯ ВЫГРУЗКА — продажи по дням × ряд прогноза
   ===================================================================== */
DECLARE @DateFrom date          = '2023-01-01';
DECLARE @DateTo   date          = EOMONTH(GETDATE(), -1);  -- конец последнего полного месяца
DECLARE @k        decimal(18,6) = 1.0;   -- коэффициент маскировки (1 = без маскировки)

WITH cards AS (
    SELECT DISTINCT
        v.CardId, v.CardAccountNo, v.ProductID,
        CAST(v.OpenDate AS date) AS OpenDay
    FROM DWH.dbo.vw_Cards v
    WHERE v.DateABS = EOMONTH(v.OpenDate)            -- срез месяца открытия
      AND v.DateABS BETWEEN EOMONTH(@DateFrom) AND @DateTo
      AND v.OpenDate >= @DateFrom
      AND v.BalanceCardAccountNo <> '00000' /* код балансового счёта-исключения */
      AND v.BusinessType = N'Розничный бизнес'
      AND v.ProductID IS NOT NULL
      AND v.CardId IS NOT NULL                       -- без карт сотрудников
      AND v.CardAccountNo NOT LIKE '%***%'
),
daily AS (
    SELECT
        c.OpenDay,
        pc.forecast_series,
        COUNT(DISTINCT c.CardAccountNo) AS sales_count,   -- новые договоры
        COUNT(DISTINCT c.CardId)        AS cards_count    -- карты по ним
    FROM cards c
    JOIN #product_class pc ON pc.ProductID = c.ProductID
    GROUP BY c.OpenDay, pc.forecast_series
),
calendar AS (
    SELECT @DateFrom AS dt
    UNION ALL
    SELECT DATEADD(day, 1, dt) FROM calendar WHERE dt < @DateTo
),
grid AS (                                            -- день × ряд, чтобы были нули
    SELECT cal.dt, s.forecast_series
    FROM calendar cal
    CROSS JOIN (SELECT DISTINCT forecast_series FROM #product_class) s
)
SELECT
    g.dt                                           AS [date],
    g.forecast_series                              AS series,
    N'Карта'                                       AS product_group,
    ROUND(COALESCE(d.sales_count, 0) * @k, 2)      AS sales_count,
    ROUND(COALESCE(d.cards_count, 0) * @k, 2)      AS cards_count
FROM grid g
LEFT JOIN daily d
       ON d.OpenDay = g.dt
      AND d.forecast_series = g.forecast_series
ORDER BY g.dt, g.forecast_series
OPTION (MAXRECURSION 0);


/* =====================================================================
   4. ДЕТАЛИЗАЦИЯ ДЛЯ EDA — по месяцам со всеми признаками
   (доли платёжных систем, премиальных карт, зарплатных, динамика по уровням)
   ===================================================================== */
WITH cards AS (
    SELECT DISTINCT v.CardAccountNo, v.ProductID, v.OpenDate
    FROM DWH.dbo.vw_Cards v
    WHERE v.DateABS = EOMONTH(v.OpenDate)
      AND v.DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND v.OpenDate >= '2023-01-01'
      AND v.BalanceCardAccountNo <> '00000' /* код балансового счёта-исключения */
      AND v.BusinessType = N'Розничный бизнес'
      AND v.CardId IS NOT NULL
      AND v.CardAccountNo NOT LIKE '%***%'
)
SELECT
    DATEFROMPARTS(YEAR(c.OpenDate), MONTH(c.OpenDate), 1) AS month_start,
    pc.forecast_series, pc.pay_system, pc.card_tier, pc.is_salary, pc.is_credit,
    COUNT(DISTINCT c.CardAccountNo)                         AS sales_count
FROM cards c
JOIN #product_class pc ON pc.ProductID = c.ProductID
GROUP BY DATEFROMPARTS(YEAR(c.OpenDate), MONTH(c.OpenDate), 1),
         pc.forecast_series, pc.pay_system, pc.card_tier, pc.is_salary, pc.is_credit
ORDER BY month_start, pc.forecast_series, pc.pay_system, pc.card_tier;


/* =====================================================================
   5. ПРОВЕРКА: карты, появившиеся в витрине позже месяца открытия
   (условие DateABS = EOMONTH(OpenDate) их теряет; должно быть ~0)
   ===================================================================== */
WITH first_snap AS (
    SELECT CardId, MIN(DateABS) AS first_DateABS, MIN(OpenDate) AS OpenDate
    FROM DWH.dbo.vw_Cards
    WHERE OpenDate >= '2023-01-01'
      AND DateABS  >= '2023-01-31'
      AND BusinessType = N'Розничный бизнес'
      AND CardId IS NOT NULL
    GROUP BY CardId
)
SELECT
    FORMAT(OpenDate, 'yyyy-MM') AS open_month,
    COUNT(*)                    AS cards,
    SUM(CASE WHEN first_DateABS > EOMONTH(OpenDate) THEN 1 ELSE 0 END) AS late_cards
FROM first_snap
GROUP BY FORMAT(OpenDate, 'yyyy-MM')
ORDER BY open_month;
