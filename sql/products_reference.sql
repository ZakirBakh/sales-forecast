/* =====================================================================
   СПРАВОЧНИК ПРОДУКТОВ: кредиты и срочные депозиты
   MS SQL Server
   ---------------------------------------------------------------------
   Для каждого продукта: валюты, сроки, ставки, дата первого открытия.
   - Дата первого открытия — по ВСЕЙ истории витрины (без ограничения 2023 г.).
   - Сроки и ставки — по договорам с 2023 г., каждый договор один раз
     (срез месяца открытия: DateABS = EOMONTH(дата открытия)).
   - Депозит = MainAccountNo (основной счёт вклада).
   - Средняя ставка — средневзвешенная по сумме договора.
   Фильтры те же, что в выгрузках продаж.

   Блоки:  К1–К3 — кредиты,  Д1–Д3 — депозиты
     1 — паспорт продукта (продукт × валюта)
     2 — ставки по срокам (продукт × валюта × срок)
     3 — история ставок по месяцам (признак для модели)
   ===================================================================== */


/* =====================================================================
   К1. КРЕДИТЫ — паспорт продукта (категория × продукт × валюта)
   ===================================================================== */
WITH first_open AS (                        -- по всей истории
    SELECT ProductUU, Product, AgreementCurrency,
           CAST(MIN(CreditOpenDate) AS date) AS first_open_ever
    FROM DWH.dbo.vw_Credits
    WHERE Bussiness   = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
      AND ProductUU IS NOT NULL
      AND ProductUU NOT IN (N'Карточный продукт 1', N'Карточный продукт 2')
    GROUP BY ProductUU, Product, AgreementCurrency
),
credits_1row AS (                           -- договоры с 2023 г., один раз
    SELECT
        CreditID,
        MAX(ProductUU)                       AS ProductUU,
        MAX(Product)                         AS Product,
        MAX(AgreementCurrency)               AS AgreementCurrency,
        CAST(MIN(CreditOpenDate) AS date)    AS OpenDay,
        MAX(AgreementInDays) / 30.44         AS term_months,
        MAX(AgreementSumN)                   AS amount,
        MAX(rate)                            AS rate
    FROM DWH.dbo.vw_Credits
    WHERE DateABS = EOMONTH(CreditOpenDate)
      AND DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND Bussiness   = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
      AND CreditOpenDate >= '2023-01-01'
      AND ProductUU IS NOT NULL
      AND ProductUU NOT IN (N'Карточный продукт 1', N'Карточный продукт 2')
    GROUP BY CreditID
)
SELECT
    f.ProductUU                                          AS category,
    COALESCE(f.Product, N'Не указан')                    AS product,
    f.AgreementCurrency                                  AS currency,
    f.first_open_ever,                                   -- первое открытие за всю историю
    MIN(c.OpenDay)                                       AS first_open_2023,
    MAX(c.OpenDay)                                       AS last_open,
    CASE WHEN MAX(c.OpenDay) < DATEADD(month, -3, EOMONTH(GETDATE(), -1))
         THEN N'Не продаётся' ELSE N'Активный' END       AS status,  -- нет выдач 3+ мес.
    COUNT(c.CreditID)                                    AS contracts_since_2023,
    ROUND(MIN(c.term_months), 1)                         AS term_min_m,
    ROUND(AVG(c.term_months), 1)                         AS term_avg_m,
    ROUND(MAX(c.term_months), 1)                         AS term_max_m,
    MIN(c.rate)                                          AS rate_min,
    ROUND(SUM(c.rate * c.amount) / NULLIF(SUM(c.amount), 0), 2) AS rate_wavg,
    MAX(c.rate)                                          AS rate_max,
    ROUND(AVG(c.amount), 0)                              AS avg_amount
FROM first_open f
LEFT JOIN credits_1row c
       ON c.ProductUU = f.ProductUU
      AND COALESCE(c.Product, N'') = COALESCE(f.Product, N'')
      AND c.AgreementCurrency = f.AgreementCurrency
GROUP BY f.ProductUU, f.Product, f.AgreementCurrency, f.first_open_ever
ORDER BY category, product, currency;
-- contracts_since_2023 = 0  -> продукт продавался только до 2023 г.


/* =====================================================================
   К2. КРЕДИТЫ — ставки по срокам (продукт × валюта × группа срока)
   ===================================================================== */
WITH credits_1row AS (
    SELECT
        CreditID,
        MAX(ProductUU)                       AS ProductUU,
        COALESCE(MAX(Product), N'Не указан') AS Product,
        MAX(AgreementCurrency)               AS Currency,
        MAX(AgreementInDays) / 30.44         AS term_months,
        MAX(AgreementSumN)                   AS amount,
        MAX(rate)                            AS rate
    FROM DWH.dbo.vw_Credits
    WHERE DateABS = EOMONTH(CreditOpenDate)
      AND DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND Bussiness   = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
      AND CreditOpenDate >= '2023-01-01'
      AND ProductUU IS NOT NULL
      AND ProductUU NOT IN (N'Карточный продукт 1', N'Карточный продукт 2')
    GROUP BY CreditID
),
bucketed AS (
    SELECT *,
        CASE
            WHEN term_months <  6.5 THEN N'1) до 6 мес'
            WHEN term_months < 12.5 THEN N'2) 7–12 мес'
            WHEN term_months < 24.5 THEN N'3) 13–24 мес'
            WHEN term_months < 36.5 THEN N'4) 25–36 мес'
            WHEN term_months < 60.5 THEN N'5) 37–60 мес'
            ELSE                         N'6) более 60 мес'
        END AS term_group
    FROM credits_1row
)
SELECT
    ProductUU AS category, Product AS product, Currency AS currency, term_group,
    COUNT(*)                                             AS contracts,
    MIN(rate)                                            AS rate_min,
    ROUND(SUM(rate * amount) / NULLIF(SUM(amount), 0), 2) AS rate_wavg,
    MAX(rate)                                            AS rate_max
FROM bucketed
GROUP BY ProductUU, Product, Currency, term_group
ORDER BY category, product, currency, term_group;


/* =====================================================================
   К3. КРЕДИТЫ — история ставок по месяцам (категория × валюта)
   Изменение средней ставки во времени — признак для модели прогноза.
   ===================================================================== */
WITH credits_1row AS (
    SELECT
        CreditID,
        MAX(ProductUU)                       AS ProductUU,
        MAX(AgreementCurrency)               AS Currency,
        EOMONTH(MIN(CreditOpenDate))         AS month_end,
        MAX(AgreementSumN)                   AS amount,
        MAX(rate)                            AS rate
    FROM DWH.dbo.vw_Credits
    WHERE DateABS = EOMONTH(CreditOpenDate)
      AND DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND Bussiness   = N'Розничный бизнес'
      AND ProjectType = N'Розничное кредитование'
      AND CreditOpenDate >= '2023-01-01'
      AND ProductUU IS NOT NULL
      AND ProductUU NOT IN (N'Карточный продукт 1', N'Карточный продукт 2')
    GROUP BY CreditID
)
SELECT
    DATEFROMPARTS(YEAR(month_end), MONTH(month_end), 1)  AS month_start,
    ProductUU AS category, Currency AS currency,
    COUNT(*)                                             AS contracts,
    MIN(rate)                                            AS rate_min,
    ROUND(SUM(rate * amount) / NULLIF(SUM(amount), 0), 2) AS rate_wavg,
    MAX(rate)                                            AS rate_max
FROM credits_1row
GROUP BY month_end, ProductUU, Currency
ORDER BY category, currency, month_start;


/* =====================================================================
   ДЕПОЗИТЫ: общая база для Д1–Д3 — строки среза месяца открытия без дублей.
   Депозит = MainAccountNo (основной счёт вклада).
   ===================================================================== */

/* =====================================================================
   Д1. ДЕПОЗИТЫ — паспорт продукта (продукт × валюта)
   ===================================================================== */
WITH first_open AS (
    SELECT ProductName, MainAccountCurrency AS Currency,
           CAST(MIN(OpenDate) AS date) AS first_open_ever
    FROM DWH.dbo.vw_Deposits
    WHERE BusinessType = N'Розничный бизнес'
      AND DepositType  = N'Срочный'
      AND ProductName IS NOT NULL
    GROUP BY ProductName, MainAccountCurrency
),
dep AS (
    SELECT DISTINCT
        MainAccountNo,
        CAST(OpenDate AS date)                  AS OpenDay,
        ProductName,
        MainAccountCurrency                     AS Currency,
        PeriodInDays,
        MainAccountBalanceNationalCurrency      AS amount,
        InterestRate                            AS rate
    FROM DWH.dbo.vw_Deposits
    WHERE DateABS = EOMONTH(OpenDate)
      AND DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND BusinessType = N'Розничный бизнес'
      AND DepositType  = N'Срочный'
      AND OpenDate >= '2023-01-01'
      AND ProductName IS NOT NULL
)
SELECT
    f.ProductName                                        AS product,
    f.Currency                                           AS currency,
    f.first_open_ever,
    MIN(d.OpenDay)                                       AS first_open_2023,
    MAX(d.OpenDay)                                       AS last_open,
    CASE WHEN MAX(d.OpenDay) < DATEADD(month, -3, EOMONTH(GETDATE(), -1))
         THEN N'Не продаётся' ELSE N'Активный' END       AS status,
    COUNT(DISTINCT CASE WHEN d.MainAccountNo IS NOT NULL
                        THEN d.MainAccountNo END)
                                                         AS contracts_since_2023,
    ROUND(MIN(d.PeriodInDays) / 30.44, 1)                AS term_min_m,
    ROUND(AVG(d.PeriodInDays * 1.0) / 30.44, 1)          AS term_avg_m,
    ROUND(MAX(d.PeriodInDays) / 30.44, 1)                AS term_max_m,
    MIN(d.rate)                                          AS rate_min,
    ROUND(SUM(d.rate * d.amount) / NULLIF(SUM(d.amount), 0), 2) AS rate_wavg,
    MAX(d.rate)                                          AS rate_max,
    ROUND(AVG(d.amount), 0)                              AS avg_amount
FROM first_open f
LEFT JOIN dep d
       ON d.ProductName = f.ProductName
      AND d.Currency    = f.Currency
GROUP BY f.ProductName, f.Currency, f.first_open_ever
ORDER BY product, currency;


/* =====================================================================
   Д2. ДЕПОЗИТЫ — ставки по срокам (продукт × валюта × срок в месяцах)
   ===================================================================== */
WITH dep AS (
    SELECT DISTINCT
        MainAccountNo,
        CAST(OpenDate AS date)                  AS OpenDay,
        ProductName,
        MainAccountCurrency                     AS Currency,
        PeriodInDays,
        MainAccountBalanceNationalCurrency      AS amount,
        InterestRate                            AS rate
    FROM DWH.dbo.vw_Deposits
    WHERE DateABS = EOMONTH(OpenDate)
      AND DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND BusinessType = N'Розничный бизнес'
      AND DepositType  = N'Срочный'
      AND OpenDate >= '2023-01-01'
      AND ProductName IS NOT NULL
)
SELECT
    ProductName AS product, Currency AS currency,
    ROUND(PeriodInDays / 30.44, 0)                       AS term_months,
    COUNT(DISTINCT MainAccountNo)                                AS contracts,
    MIN(rate)                                            AS rate_min,
    ROUND(SUM(rate * amount) / NULLIF(SUM(amount), 0), 2) AS rate_wavg,
    MAX(rate)                                            AS rate_max
FROM dep
GROUP BY ProductName, Currency, ROUND(PeriodInDays / 30.44, 0)
ORDER BY product, currency, term_months;


/* =====================================================================
   Д3. ДЕПОЗИТЫ — история ставок по месяцам (валюта × срок)
   ===================================================================== */
WITH dep AS (
    SELECT DISTINCT
        MainAccountNo,
        CAST(OpenDate AS date)                  AS OpenDay,
        ProductName,
        MainAccountCurrency                     AS Currency,
        PeriodInDays,
        MainAccountBalanceNationalCurrency      AS amount,
        InterestRate                            AS rate
    FROM DWH.dbo.vw_Deposits
    WHERE DateABS = EOMONTH(OpenDate)
      AND DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND BusinessType = N'Розничный бизнес'
      AND DepositType  = N'Срочный'
      AND OpenDate >= '2023-01-01'
      AND ProductName IS NOT NULL
)
SELECT
    DATEFROMPARTS(YEAR(OpenDay), MONTH(OpenDay), 1)      AS month_start,
    Currency AS currency,
    ROUND(PeriodInDays / 30.44, 0)                       AS term_months,
    COUNT(DISTINCT MainAccountNo)                                AS contracts,
    MIN(rate)                                            AS rate_min,
    ROUND(SUM(rate * amount) / NULLIF(SUM(amount), 0), 2) AS rate_wavg,
    MAX(rate)                                            AS rate_max
FROM dep
GROUP BY DATEFROMPARTS(YEAR(OpenDay), MONTH(OpenDay), 1), Currency, ROUND(PeriodInDays / 30.44, 0)
ORDER BY currency, term_months, month_start;


/* =====================================================================
   Д4. СВЕРКА КЛЮЧЕЙ: какой счёт ближе к реальному числу открытий
   ===================================================================== */
WITH dep AS (
    SELECT DISTINCT
        MainAccountNo,
        DepositNo,
        CAST(OpenDate AS date)                  AS OpenDay,
        ProductName,
        MainAccountCurrency                     AS Currency
    FROM DWH.dbo.vw_Deposits
    WHERE DateABS = EOMONTH(OpenDate)
      AND DateABS BETWEEN '2023-01-31' AND EOMONTH(GETDATE(), -1)
      AND BusinessType = N'Розничный бизнес'
      AND DepositType  = N'Срочный'
      AND OpenDate >= '2023-01-01'
      AND ProductName IS NOT NULL
)
SELECT
    COUNT(DISTINCT MainAccountNo)                                       AS by_main_account,
    COUNT(DISTINCT DepositNo)                                           AS by_deposit_no,
    COUNT(DISTINCT CONCAT(DepositNo, '|', OpenDay, '|', ProductName, '|', Currency))
                                                                        AS by_deposit_no_combo,
    (SELECT COUNT(*) FROM (SELECT MainAccountNo FROM dep GROUP BY MainAccountNo
        HAVING COUNT(DISTINCT DepositNo) > 1) x)                         AS accounts_with_many_deposit_no,
    (SELECT COUNT(*) FROM (SELECT DepositNo FROM dep GROUP BY DepositNo
        HAVING COUNT(DISTINCT MainAccountNo) > 1) y)                     AS deposit_no_with_many_accounts
FROM dep;
-- by_main_account ≈ реальному числу открытий => MainAccountNo — правильный ключ;
-- deposit_no_with_many_accounts > 0 подтверждает, что под одним DepositNo несколько вкладов.
