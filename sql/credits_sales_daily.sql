/* =====================================================================
   Выдачи и погашения кредитов по дням — проект «Прогноз продаж»
   MS SQL Server
   ---------------------------------------------------------------------
   Витрина хранит помесячные срезы (DateABS = конец месяца, кредит повторяется
   в каждом месяце, пока не погашен; проверка 0: ~12 строк на кредит).
   => выдачи берутся из среза месяца выдачи: DateABS = EOMONTH(CreditOpenDate):
      одна строка на кредит, сумма и ставка — на момент выдачи.
   => погашения — по всем срезам, т.к. дата погашения появляется позже.
   Выдачи и погашения собраны в одну таблицу (запрос 2) на общей сетке
   день × ProductUU × канал × валюта.

   Ряды прогноза = продукты (Product) внутри категорий (ProductUU);
   фильтры — по категории ProductUU.
   Исключены карточные продукты (они в рядах карт):
     «Карточный продукт 1», «Карточный продукт 2».

   ПОРЯДОК ЗАПУСКА: 0 -> 1 (проверить) -> 2 -> 3 -> 4
   ===================================================================== */


/* =====================================================================
   0. ПРОВЕРКА: строк на кредит (уже выполнена: 42 170 строк / 3 578 кредитов)
   ===================================================================== */
SELECT
    COUNT(*)                  AS rows_cnt,
    COUNT(DISTINCT CreditID)  AS credits
FROM DWH.dbo.vw_Credits
WHERE Bussiness = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
  AND CreditOpenDate >= '2025-01-01'
  AND CreditOpenDate <  '2025-02-01';


/* =====================================================================
   1. КАТЕГОРИИ ProductUU: объёмы и период жизни
   - убедиться, что исключённые карточные продукты названы точно так,
     как в витрине (колонка excluded = 1);
   - категории со средним < ~10 выдач в день лучше объединить
   ===================================================================== */
WITH credits_1row AS (
    SELECT DISTINCT CreditID, ProductUU, CAST(CreditOpenDate AS date) AS OpenDay
    FROM DWH.dbo.vw_Credits
    WHERE DateABS = EOMONTH(CreditOpenDate)
      AND DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND Bussiness = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
      AND CreditOpenDate >= '2023-01-01'
)
SELECT
    ProductUU,
    CASE WHEN ProductUU IN (N'Карточный продукт 1', N'Карточный продукт 2')
         THEN 1 ELSE 0 END                                  AS excluded,
    MIN(OpenDay)                                            AS first_issue,
    MAX(OpenDay)                                            AS last_issue,
    COUNT(DISTINCT CreditID)                                AS credits_total,
    COUNT(DISTINCT CreditID) * 1.0
      / (DATEDIFF(day, '2023-01-01', EOMONTH(GETDATE(), -1)) + 1)
                                                            AS avg_per_day
FROM credits_1row
GROUP BY ProductUU
ORDER BY credits_total DESC;


/* =====================================================================
   2. ОСНОВНАЯ ВЫГРУЗКА — ЕДИНАЯ ТАБЛИЦА: выдачи + погашения
   Одна строка = день × категория (ProductUU) × продукт (Product) × канал × валюта.
   - Фильтры (исключения, пустые значения) — по КАТЕГОРИИ ProductUU,
     группировка — по категории и названию продукта.
   - Каждый кредит сводится к ОДНОЙ строке (GROUP BY CreditID), поэтому
     он не может попасть в два продукта и задвоить сумму.
   - Пустое название продукта не теряется: «Не указан».
   => сумма по всем строкам = итог по категориям ProductUU.
   ===================================================================== */
DECLARE @DateFrom date          = '2023-01-01';
DECLARE @DateTo   date          = EOMONTH(GETDATE(), -1);  -- конец последнего полного месяца
DECLARE @k        decimal(18,6) = 1.0;   -- коэффициент маскировки сумм (1 = без маскировки)

WITH
-- 2.1 Выдачи: одна строка на кредит из среза месяца выдачи
issued AS (
    SELECT
        CreditID,
        CAST(MIN(CreditOpenDate) AS date)               AS dt,
        MAX(ProductUU)                                  AS ProductUU,
        COALESCE(MAX(Product), N'Не указан')            AS Product,
        MAX(CASE WHEN OfficerIssuedCredit = 'ONLINE_SCORING'
                 THEN N'Онлайн' ELSE N'Оффлайн' END)    AS Channel,
        MAX(AgreementCurrency)                          AS Currency,
        MAX(AgreementSumN)                              AS AgreementSumN,
        MAX(AgreementInDays)                            AS AgreementInDays,
        MAX(rate)                                       AS rate
    FROM DWH.dbo.vw_Credits
    WHERE DateABS = EOMONTH(CreditOpenDate)             -- только срез месяца выдачи
      AND DateABS BETWEEN EOMONTH(@DateFrom) AND @DateTo
      AND Bussiness   = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
      AND CreditOpenDate >= @DateFrom
      AND ProductUU IS NOT NULL
      AND ProductUU NOT IN (N'Карточный продукт 1', N'Карточный продукт 2')
    GROUP BY CreditID
),
issued_daily AS (
    SELECT
        dt, ProductUU, Product, Channel, Currency,
        COUNT(*)                                        AS sales_count,
        SUM(AgreementSumN)                              AS sales_amount,
        AVG(AgreementInDays * 1.0) / 30.44              AS avg_term_months,
        SUM(rate * AgreementSumN)
            / NULLIF(SUM(AgreementSumN), 0)             AS wavg_rate
    FROM issued
    GROUP BY dt, ProductUU, Product, Channel, Currency
),
-- 2.2 Погашения: одна строка на кредит, дата погашения из любого среза
repaid AS (
    SELECT
        CreditID,
        CAST(MAX(FactRepaymentDate) AS date)            AS dt,
        MAX(ProductUU)                                  AS ProductUU,
        COALESCE(MAX(Product), N'Не указан')            AS Product,
        MAX(CASE WHEN OfficerIssuedCredit = 'ONLINE_SCORING'
                 THEN N'Онлайн' ELSE N'Оффлайн' END)    AS Channel,
        MAX(AgreementCurrency)                          AS Currency,
        MAX(CASE WHEN EarlyOrOnTerm = N'Досрочно'
                 THEN 1 ELSE 0 END)                     AS is_early
    FROM DWH.dbo.vw_Credits
    WHERE Bussiness   = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
      AND FactRepaymentDate >= @DateFrom
      AND FactRepaymentDate <  DATEADD(day, 1, @DateTo)
      AND ProductUU IS NOT NULL
      AND ProductUU NOT IN (N'Карточный продукт 1', N'Карточный продукт 2')
    GROUP BY CreditID
),
repaid_daily AS (
    SELECT
        dt, ProductUU, Product, Channel, Currency,
        COUNT(*)                                        AS closures_count,
        SUM(is_early)                                   AS early_closures
    FROM repaid
    GROUP BY dt, ProductUU, Product, Channel, Currency
),
-- 2.3 Общая сетка: все дни × все ряды из выдач ИЛИ погашений
calendar AS (
    SELECT @DateFrom AS dt
    UNION ALL
    SELECT DATEADD(day, 1, dt) FROM calendar WHERE dt < @DateTo
),
series AS (
    SELECT ProductUU, Product, Channel, Currency FROM issued_daily
    UNION
    SELECT ProductUU, Product, Channel, Currency FROM repaid_daily
),
grid AS (
    SELECT cal.dt, s.ProductUU, s.Product, s.Channel, s.Currency
    FROM calendar cal CROSS JOIN series s
)
SELECT
    g.dt                                              AS [date],
    g.ProductUU                                       AS category,
    g.Product                                         AS series,
    N'Кредит'                                         AS product_group,
    g.Channel                                         AS channel,
    g.Currency                                        AS currency,
    COALESCE(i.sales_count, 0)                        AS sales_count,
    ROUND(COALESCE(i.sales_amount, 0) * @k, 2)        AS sales_amount,
    ROUND(i.avg_term_months, 1)                       AS avg_term_months,  -- NULL в дни без выдач
    ROUND(i.wavg_rate, 2)                             AS wavg_rate,        -- NULL в дни без выдач
    COALESCE(r.closures_count, 0)                     AS closures_count,
    COALESCE(r.early_closures, 0)                     AS early_closures
FROM grid g
LEFT JOIN issued_daily i
       ON i.dt = g.dt AND i.ProductUU = g.ProductUU AND i.Product = g.Product
      AND i.Channel = g.Channel AND i.Currency = g.Currency
LEFT JOIN repaid_daily r
       ON r.dt = g.dt AND r.ProductUU = g.ProductUU AND r.Product = g.Product
      AND r.Channel = g.Channel AND r.Currency = g.Currency
ORDER BY g.dt, g.ProductUU, g.Product, g.Channel, g.Currency
OPTION (MAXRECURSION 0);


/* =====================================================================
   2.4 КОНТРОЛЬ ИТОГОВ: должно совпасть с суммой sales_count / sales_amount
   из запроса 2 (по всем строкам). Считается по категориям, без Product.
   ===================================================================== */
SELECT
    COUNT(DISTINCT CreditID)        AS credits_total,
    SUM(AgreementSumN)              AS amount_total
FROM (
    SELECT CreditID, MAX(AgreementSumN) AS AgreementSumN
    FROM DWH.dbo.vw_Credits
    WHERE DateABS = EOMONTH(CreditOpenDate)
      AND DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND Bussiness   = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
      AND CreditOpenDate >= '2023-01-01'
      AND ProductUU IS NOT NULL
      AND ProductUU NOT IN (N'Карточный продукт 1', N'Карточный продукт 2')
    GROUP BY CreditID
) x;


/* =====================================================================
   3. СВЕРКА с исходным отчётом (год × категория × валюта × канал)
   Количество должно совпасть с исходным; суммы будут меньше —
   исходный SUM(AgreementSumN) складывал все срезы кредита.
   ===================================================================== */
WITH credits_1row AS (
    SELECT DISTINCT
        CreditID,
        YEAR(CreditOpenDate)                       AS yr,
        ProductUU,
        AgreementCurrency                          AS Currency,
        CASE WHEN OfficerIssuedCredit = 'ONLINE_SCORING'
             THEN N'Онлайн' ELSE N'Оффлайн' END    AS Channel,
        AgreementSumN
    FROM DWH.dbo.vw_Credits
    WHERE DateABS = EOMONTH(CreditOpenDate)
      AND Bussiness = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
      AND CreditOpenDate >= '2023-01-01'
      AND CreditOpenDate <= '2026-09-30'
      AND ProductUU NOT IN (N'Карточный продукт 1', N'Карточный продукт 2')
)
SELECT yr AS [Год], ProductUU, Currency, Channel AS [Канал продаж],
       COUNT(DISTINCT CreditID) AS [Кол-во выданных кредитов],
       SUM(AgreementSumN)       AS [Сумма выдач]
FROM credits_1row
GROUP BY yr, ProductUU, Currency, Channel
ORDER BY [Год], ProductUU, Currency, [Канал продаж];


/* =====================================================================
   4. ПРОВЕРКИ условия «срез месяца выдачи»
   ===================================================================== */

-- 4.1 Все ли кредиты есть в срезе месяца выдачи (late_credits должно быть ~0)
WITH first_snap AS (
    SELECT CreditID, MIN(DateABS) AS first_DateABS, MIN(CreditOpenDate) AS OpenDate
    FROM DWH.dbo.vw_Credits
    WHERE Bussiness = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
      AND CreditOpenDate >= '2023-01-01'
    GROUP BY CreditID
)
SELECT FORMAT(OpenDate, 'yyyy-MM') AS open_month,
       COUNT(*) AS credits,
       SUM(CASE WHEN first_DateABS > EOMONTH(OpenDate) THEN 1 ELSE 0 END) AS late_credits
FROM first_snap
GROUP BY FORMAT(OpenDate, 'yyyy-MM')
ORDER BY open_month;

-- 4.2 Меняются ли сумма и ставка между срезами
SELECT
    AgreementCurrency,
    COUNT(*) AS credits,
    SUM(CASE WHEN min_sum  <> max_sum  THEN 1 ELSE 0 END) AS sum_changes,
    SUM(CASE WHEN min_rate <> max_rate THEN 1 ELSE 0 END) AS rate_changes
FROM (
    SELECT CreditID, MAX(AgreementCurrency) AS AgreementCurrency,
           MIN(AgreementSumN) AS min_sum,  MAX(AgreementSumN) AS max_sum,
           MIN(rate)          AS min_rate, MAX(rate)          AS max_rate
    FROM DWH.dbo.vw_Credits
    WHERE Bussiness = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
      AND CreditOpenDate >= '2025-01-01' AND CreditOpenDate < '2025-02-01'
    GROUP BY CreditID
) x
GROUP BY AgreementCurrency;
-- sum_changes > 0 только у валютных => AgreementSumN = сомовый эквивалент по курсу среза;
--   в выгрузке сумма по курсу месяца выдачи — корректно.
-- sum_changes > 0 у сомовых => поле похоже на остаток, а не сумму договора — сообщите.
