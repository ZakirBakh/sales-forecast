/* =====================================================================
   Открытия и закрытия СРОЧНЫХ депозитов по дням — проект «Прогноз продаж»
   MS SQL Server
   ---------------------------------------------------------------------
   Логика как у кредитов:
   - открытия берутся из среза месяца открытия: DateABS = EOMONTH(OpenDate)
     (одна строка на депозит, сумма и ставка — на конец месяца открытия);
   - открытия считаются как COUNT(DISTINCT DepositNo) в каждом ряду — эта логика
     сверена с реальными цифрами; под одним DepositNo в один день может быть
     несколько вкладов разных продуктов / валют;
   - закрытия — по всем срезам (дата закрытия появляется позже);
   - выдачи и закрытия на общей сетке: день × продукт × канал × валюта.

   ПОРЯДОК ЗАПУСКА: 0 -> 1 (проверить) -> 2 -> 3
   ===================================================================== */


/* =====================================================================
   0. ПРОВЕРКА: срезы в витрине депозитов (ожидаем rows_cnt >> deposits)
   ===================================================================== */
SELECT
    COUNT(*)                   AS rows_cnt,
    COUNT(DISTINCT DepositNo)  AS deposits
FROM DWH.dbo.vw_Deposits
WHERE BusinessType = N'Розничный бизнес'
  AND DepositType  = N'Срочный'
  AND OpenDate >= '2025-01-01'
  AND OpenDate <  '2025-02-01';


/* =====================================================================
   1. ПРОДУКТЫ: объёмы и период жизни
   Если продуктов много — мелкие (< ~10 открытий в день) стоит объединить
   (например, по сроку и валюте) или использовать категорию продукта,
   если такое поле есть в витрине.
   ===================================================================== */
WITH dep_1row AS (
    SELECT DISTINCT DepositNo, ProductName, CAST(OpenDate AS date) AS OpenDay
    FROM DWH.dbo.vw_Deposits
    WHERE DateABS = EOMONTH(OpenDate)
      AND DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND BusinessType = N'Розничный бизнес'
      AND DepositType  = N'Срочный'
      AND OpenDate >= '2023-01-01'
)
SELECT
    ProductName,
    MIN(OpenDay)                       AS first_open,
    MAX(OpenDay)                       AS last_open,
    COUNT(DISTINCT DepositNo)          AS deposits_total,
    COUNT(DISTINCT DepositNo) * 1.0
      / (DATEDIFF(day, '2023-01-01', EOMONTH(GETDATE(), -1)) + 1)
                                       AS avg_per_day
FROM dep_1row
GROUP BY ProductName
ORDER BY deposits_total DESC;


/* =====================================================================
   2. ОСНОВНАЯ ВЫГРУЗКА — ЕДИНАЯ ТАБЛИЦА: открытия + закрытия
   ===================================================================== */
DECLARE @DateFrom date          = '2023-01-01';
DECLARE @DateTo   date          = EOMONTH(GETDATE(), -1);  -- конец последнего полного месяца
DECLARE @k        decimal(18,6) = 1.0;   -- коэффициент маскировки сумм (1 = без маскировки)

WITH
-- 2.1 Открытия: одна строка на депозит из среза месяца открытия
opened AS (                -- строки среза месяца открытия, без дублей (как в эталонной выгрузке)
    SELECT DISTINCT
        DepositNo,
        CAST(OpenDate AS date)                     AS dt,
        ProductName,
        CASE WHEN CreateUserName IN ('ib_user_1', 'ib_user_2', 'ib_user_3', 'ib_user_4')
             THEN N'Онлайн' ELSE N'Оффлайн' END    AS Channel,
        MainAccountCurrency                        AS Currency,
        MainAccountBalanceNationalCurrency         AS Amount,   -- остаток на конец месяца открытия
        PeriodInDays,
        InterestRate
    FROM DWH.dbo.vw_Deposits
    WHERE DateABS = EOMONTH(OpenDate)
      AND DateABS BETWEEN EOMONTH(@DateFrom) AND @DateTo
      AND BusinessType = N'Розничный бизнес'
      AND DepositType  = N'Срочный'
      AND OpenDate >= @DateFrom
      AND ProductName IS NOT NULL
),
opened_daily AS (
    SELECT
        dt, ProductName, Channel, Currency,
        COUNT(DISTINCT DepositNo)                       AS sales_count,
        SUM(Amount)                                     AS sales_amount,
        AVG(PeriodInDays * 1.0) / 30.44                 AS avg_term_months,
        SUM(InterestRate * Amount)
            / NULLIF(SUM(Amount), 0)                    AS wavg_rate    -- средневзвешенная по сумме
    FROM opened
    GROUP BY dt, ProductName, Channel, Currency
),
-- 2.2 Закрытия: дата закрытия из любого среза.
--     Депозит = номер + дата открытия + продукт + валюта: под одним номером
--     в один день могут быть разные вклады — они не склеиваются.
--     Включает депозиты, открытые до 2023 г. (их закрытия — тоже отток средств).
closed AS (
    SELECT
        DepositNo,
        CAST(MAX(FactCloseDate) AS date)           AS dt,
        ProductName,
        CASE WHEN MAX(CASE WHEN CreateUserName IN ('ib_user_1', 'ib_user_2', 'ib_user_3', 'ib_user_4')
                           THEN 1 ELSE 0 END) = 1
             THEN N'Онлайн' ELSE N'Оффлайн' END     AS Channel,
        MainAccountCurrency                        AS Currency,
        MAX(CASE WHEN CAST(CloseDate AS date) > CAST(FactCloseDate AS date)
                 THEN 1 ELSE 0 END)                AS is_early  -- закрыт раньше даты по договору
    FROM DWH.dbo.vw_Deposits
    WHERE BusinessType = N'Розничный бизнес'
      AND DepositType  = N'Срочный'
      AND FactCloseDate >= @DateFrom
      AND FactCloseDate <  DATEADD(day, 1, @DateTo)
      AND ProductName IS NOT NULL
    GROUP BY DepositNo, CAST(OpenDate AS date), ProductName, MainAccountCurrency
),
closed_daily AS (
    SELECT
        dt, ProductName, Channel, Currency,
        COUNT(*)            AS closures_count,
        SUM(is_early)       AS early_closures
    FROM closed
    GROUP BY dt, ProductName, Channel, Currency
),
-- 2.3 Общая сетка: все дни × все ряды из открытий ИЛИ закрытий
calendar AS (
    SELECT @DateFrom AS dt
    UNION ALL
    SELECT DATEADD(day, 1, dt) FROM calendar WHERE dt < @DateTo
),
series AS (
    SELECT ProductName, Channel, Currency FROM opened_daily
    UNION
    SELECT ProductName, Channel, Currency FROM closed_daily
),
grid AS (
    SELECT cal.dt, s.ProductName, s.Channel, s.Currency
    FROM calendar cal CROSS JOIN series s
)
SELECT
    g.dt                                            AS [date],
    g.ProductName                                   AS series,
    N'Депозит'                                      AS product_group,
    g.Channel                                       AS channel,
    g.Currency                                      AS currency,
    COALESCE(o.sales_count, 0)                      AS sales_count,
    ROUND(COALESCE(o.sales_amount, 0) * @k, 2)      AS sales_amount,
    ROUND(o.avg_term_months, 1)                     AS avg_term_months,  -- NULL в дни без открытий
    ROUND(o.wavg_rate, 2)                           AS wavg_rate,        -- NULL в дни без открытий
    COALESCE(c.closures_count, 0)                   AS closures_count,
    COALESCE(c.early_closures, 0)                   AS early_closures
FROM grid g
LEFT JOIN opened_daily o
       ON o.dt = g.dt AND o.ProductName = g.ProductName
      AND o.Channel = g.Channel AND o.Currency = g.Currency
LEFT JOIN closed_daily c
       ON c.dt = g.dt AND c.ProductName = g.ProductName
      AND c.Channel = g.Channel AND c.Currency = g.Currency
ORDER BY g.dt, g.ProductName, g.Channel, g.Currency
OPTION (MAXRECURSION 0);


/* =====================================================================
   3. ПРОВЕРКИ
   ===================================================================== */

-- 3.1 Все ли депозиты есть в срезе месяца открытия (late_deposits ~ 0)
WITH first_snap AS (
    SELECT DepositNo, MIN(DateABS) AS first_DateABS, CAST(OpenDate AS date) AS OpenDate
    FROM DWH.dbo.vw_Deposits
    WHERE BusinessType = N'Розничный бизнес'
      AND DepositType  = N'Срочный'
      AND OpenDate >= '2023-01-01'
    GROUP BY DepositNo, CAST(OpenDate AS date)
)
SELECT FORMAT(OpenDate, 'yyyy-MM') AS open_month,
       COUNT(*) AS deposits,
       SUM(CASE WHEN first_DateABS > EOMONTH(OpenDate) THEN 1 ELSE 0 END) AS late_deposits
FROM first_snap
GROUP BY FORMAT(OpenDate, 'yyyy-MM')
ORDER BY open_month;

-- 3.2 Депозиты, открытые и закрытые в одном месяце: у них остаток на конец
--     месяца открытия = 0, поэтому sales_amount по ним будет 0 (см. примечание)
SELECT FORMAT(OpenDate, 'yyyy-MM') AS open_month,
       COUNT(DISTINCT DepositNo)   AS deposits,
       COUNT(DISTINCT CASE WHEN MainAccountBalanceNationalCurrency = 0
                           THEN DepositNo END) AS zero_balance
FROM DWH.dbo.vw_Deposits
WHERE DateABS = EOMONTH(OpenDate)
  AND BusinessType = N'Розничный бизнес'
  AND DepositType  = N'Срочный'
  AND OpenDate >= '2023-01-01'
GROUP BY FORMAT(OpenDate, 'yyyy-MM')
ORDER BY open_month;

-- 3.3 Пролонгации: если при продлении создаётся НОВЫЙ DepositNo, то в один день
--     будут закрытие «в срок» и открытие того же продукта — это не новая продажа.
--     Сравните число закрытий в срок и открытий по дням: сильная синхронность —
--     признак того, что пролонгации попадают в продажи.
