-- ========================================================================
-- KajoDataSpace - Analiza retencji: kompletny zestaw kwerend SQL
-- ========================================================================
-- Autor: Piotr Rzepka
-- Stack: MySQL 8+
-- Dokument towarzyszacy: KDS_analiza_kompletna.md
-- Ostatnia modyfikacja: 30.04.2026
--
-- STRUKTURA PLIKU:
--   1. Widoki bazowe (vw_promo_classification, vw_fct_clients_v1, _v15)
--   2. Kwerendy analityczne (akwizycja, retencja, podwyzki)
--   3. Kwerendy walidacyjne (sygnatura cenowa, weryfikacje)
--
-- KOLEJNOSC URUCHOMIENIA:
--   1. Sekcja 1 - utworz wszystkie widoki
--   2. Sekcje 2 i 3 - mozesz uruchamiac niezaleznie
--
-- ZALEZNOSCI ZEWNETRZNE:
--   Wymagana tabela: transactions (transaction_date, client_id, amount)
-- ========================================================================


-- ========================================================================
-- SEKCJA 1: WIDOKI BAZOWE
-- ========================================================================


-- ------------------------------------------------------------------------
-- 1.1. vw_promo_classification
-- ------------------------------------------------------------------------
-- Cel: Klasyfikacja epizodow cenowych yearly na 5 kategorii biznesowych
--      (classic_promo / fomo / grandfathering / price_hike / uncertain)
-- Odnosi sie do: Etap 2 raportu (sekcja 4)
-- Output: 25 wierszy (po jednym na wyspe yearly-kandydata)
-- ------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_promo_classification;

CREATE VIEW vw_promo_classification AS
WITH transactions_segmented AS (
    -- Surowe transakcje wzbogacone o segment.
    -- Zrodlo do liczenia max cen w oknach kontekstowych wokol wysp.
    SELECT
        transaction_date,
        amount,
        CASE
            WHEN amount < 250 THEN 'monthly_sub'
            WHEN amount < 750 THEN 'course_pack'
            ELSE                   'yearly'
        END AS segment
    FROM transactions
),
gaps AS (
    -- Dla kazdej transakcji: poprzednia transakcja tej samej kwoty + odstep dni
    SELECT
        amount,
        transaction_date,
        LAG(transaction_date) OVER (
            PARTITION BY amount ORDER BY transaction_date
        ) AS prev_date,
        DATEDIFF(
            transaction_date,
            LAG(transaction_date) OVER (
                PARTITION BY amount ORDER BY transaction_date
            )
        ) AS gap_days
    FROM transactions
),
island_flags AS (
    -- Flaga nowej wyspy: gap > 7 dni lub pierwsza transakcja kwoty
    SELECT
        *,
        CASE
            WHEN gap_days > 7 OR gap_days IS NULL THEN 1
            ELSE 0
        END AS is_new_island
    FROM gaps
),
islands AS (
    -- Numer wyspy per kwota (skumulowana suma flag)
    SELECT
        *,
        SUM(is_new_island) OVER (
            PARTITION BY amount ORDER BY transaction_date
        ) AS island_id
    FROM island_flags
),
island_stats AS (
    -- Agregaty per wyspa: first_seen, last_seen, txn_cnt, span_days, density, segment
    SELECT
        amount,
        island_id,
        MIN(transaction_date) AS first_seen,
        MAX(transaction_date) AS last_seen,
        COUNT(transaction_date) AS txn_cnt,
        DATEDIFF(MAX(transaction_date), MIN(transaction_date)) AS span_days,
        ROUND(
            COUNT(transaction_date) * 1.0
            / NULLIF(DATEDIFF(MAX(transaction_date), MIN(transaction_date)) + 1, 0),
            2
        ) AS density,
        CASE
            WHEN amount < 250 THEN 'monthly_sub'
            WHEN amount < 750 THEN 'course_pack'
            ELSE                   'yearly'
        END AS segment
    FROM islands
    GROUP BY amount, island_id
),
candidates AS (
    -- Wyroznienie potencjalnych dni promocji.
    -- Progi segment-specyficzne:
    --   monthly_sub: density >= 3.0 (P90 rozkladu), txn_cnt >= 5
    --   yearly:      density >= 0.8 (min wsrod znanych promocji), txn_cnt >= 2
    SELECT
        *,
        CASE
            WHEN segment = 'monthly_sub' AND density >= 3.0 AND txn_cnt >= 5 THEN 1
            WHEN segment = 'yearly'      AND density >= 0.8 AND txn_cnt >= 2 THEN 1
            ELSE 0
        END AS is_candidate
    FROM island_stats
),
yearly_with_context AS (
    -- Dla kazdej rocznej wyspy-kandydata: max cena w segmencie yearly
    -- w oknie 60 dni wstecz i 60 dni w przod (z wykluczeniem samej wyspy).
    -- Sluzy do wyliczenia rabatu procentowego.
    SELECT
        c.*,
        (SELECT MAX(ts.amount)
         FROM transactions_segmented ts
         WHERE ts.segment = 'yearly'
           AND ts.transaction_date >= DATE_SUB(c.first_seen, INTERVAL 60 DAY)
           AND ts.transaction_date <  c.first_seen) AS max_price_before_60d,
        (SELECT MAX(ts.amount)
         FROM transactions_segmented ts
         WHERE ts.segment = 'yearly'
           AND ts.transaction_date >  c.last_seen
           AND ts.transaction_date <= DATE_ADD(c.last_seen, INTERVAL 60 DAY)) AS max_price_after_60d
    FROM candidates c
    WHERE c.is_candidate = 1 AND c.segment = 'yearly'
),
promo_classification AS (
    -- Klasyfikacja na 5 kategorii biznesowych.
    -- Kolejnosc CASE WHEN: od najbardziej specyficznej do ogolnej.
    SELECT
        *,
        ROUND((max_price_before_60d - amount) / max_price_before_60d * 100, 1) AS disc_before,
        ROUND((max_price_after_60d  - amount) / max_price_after_60d  * 100, 1) AS disc_after,
        CASE
            WHEN max_price_before_60d IS NULL OR max_price_after_60d IS NULL
                THEN 'uncertain'
            WHEN (max_price_before_60d - amount) / max_price_before_60d * 100 < 0
              OR (max_price_after_60d  - amount) / max_price_after_60d  * 100 < 0
                THEN 'price_hike'
            WHEN (max_price_before_60d - amount) / max_price_before_60d * 100 > 45
              OR (max_price_after_60d  - amount) / max_price_after_60d  * 100 > 45
                THEN 'grandfathering'
            WHEN (max_price_before_60d - amount) / max_price_before_60d * 100 BETWEEN 10 AND 45
             AND (max_price_after_60d  - amount) / max_price_after_60d  * 100 BETWEEN 10 AND 45
                THEN 'classic_promo'
            WHEN (max_price_after_60d  - amount) / max_price_after_60d  * 100 BETWEEN 10 AND 45
             AND (max_price_before_60d - amount) / max_price_before_60d * 100 < 10
                THEN 'fomo'
            ELSE 'noise'
        END AS promo_type
    FROM yearly_with_context
)
SELECT
    promo_type,
    first_seen,
    last_seen,
    amount,
    txn_cnt,
    span_days,
    density,
    max_price_before_60d,
    disc_before,
    max_price_after_60d,
    disc_after
FROM promo_classification;


-- ------------------------------------------------------------------------
-- 1.2. vw_fct_clients_v1
-- ------------------------------------------------------------------------
-- Cel: Tabela jeden-wiersz-per-klient z atrybutami pozyskania
-- Odnosi sie do: Etap 1 raportu (sekcja 3.3)
-- Output: 1057 wierszy (= liczba unikalnych klientow w transactions)
-- ------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_fct_clients_v1;

CREATE VIEW vw_fct_clients_v1 AS
WITH ordered_transactions AS (
    -- Ranking transakcji per klient.
    -- Tie-breaker: przy remisie daty wygrywa nizsza kwota.
    SELECT
        client_id,
        transaction_date,
        amount,
        ROW_NUMBER() OVER (
            PARTITION BY client_id
            ORDER BY transaction_date, amount
        ) AS rn
    FROM transactions
),
first_transaction AS (
    -- Pierwsza transakcja kazdego klienta - data + kwota
    SELECT
        client_id,
        transaction_date AS first_transaction_date,
        amount           AS first_amount
    FROM ordered_transactions
    WHERE rn = 1
)
SELECT
    f.client_id,
    f.first_transaction_date,
    f.first_amount,
    -- Era pozyskania (kalendarzowa, sztywne granice z analizy yearly)
    CASE
        WHEN f.first_transaction_date < '2024-09-01' THEN 'Era_1'
        WHEN f.first_transaction_date < '2025-10-01' THEN 'Era_2'
        ELSE                                              'Era_3'
    END AS acquisition_era,
    -- Segment pozyskania (na podstawie kwoty pierwszej transakcji)
    CASE
        WHEN f.first_amount < 250 THEN 'monthly_sub'
        WHEN f.first_amount < 750 THEN 'course_pack'
        ELSE                           'yearly'
    END AS acquisition_segment
FROM first_transaction f;


-- ------------------------------------------------------------------------
-- 1.3. vw_fct_clients_v15
-- ------------------------------------------------------------------------
-- Cel: Rozszerzenie v1 o kolumne acquisition_category
--      (new_in_promo / reactivated_by_promo / organic)
-- Odnosi sie do: Etap 5 raportu (sekcja 7) - definicje kohort
-- Zaleznosci: vw_fct_clients_v1, vw_promo_classification
-- ------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_fct_clients_v15;

CREATE VIEW vw_fct_clients_v15 AS
WITH promo_purchases AS (
    -- Wszystkie transakcje klientow trafiajace w wyspe promocyjna
    -- (matchujemy po dacie w oknie wyspy I cenie wyspy)
    SELECT
        t.client_id,
        t.transaction_date AS promo_date,
        t.amount
    FROM transactions t
    JOIN vw_promo_classification pc
      ON pc.promo_type IN ('classic_promo', 'fomo')
     AND t.transaction_date BETWEEN pc.first_seen AND pc.last_seen
     AND t.amount = pc.amount
),
first_promo_per_client AS (
    -- Najwczesniejsza transakcja promocyjna kazdego klienta + poprzedzajaca
    SELECT
        pp.client_id,
        MIN(pp.promo_date) AS first_promo_date,
        (SELECT MAX(t2.transaction_date)
         FROM transactions t2
         WHERE t2.client_id = pp.client_id
           AND t2.transaction_date < MIN(pp.promo_date)) AS prev_txn_date
    FROM promo_purchases pp
    GROUP BY pp.client_id
)
SELECT
    v1.*,
    CASE
        -- new_in_promo: pierwsza w historii transakcja = pierwsza promocyjna
        WHEN fp.first_promo_date = v1.first_transaction_date
         AND v1.acquisition_segment = 'yearly'
            THEN 'new_in_promo'
        -- reactivated_by_promo: byla wczesniejsza transakcja, przerwa > 370 dni
        WHEN fp.first_promo_date IS NOT NULL
         AND fp.prev_txn_date IS NOT NULL
         AND DATEDIFF(fp.first_promo_date, fp.prev_txn_date) > 370
         AND v1.acquisition_segment = 'yearly'
            THEN 'reactivated_by_promo'
        ELSE 'organic'
    END AS acquisition_category
FROM vw_fct_clients_v1 v1
LEFT JOIN first_promo_per_client fp USING (client_id);


-- ========================================================================
-- SEKCJA 2: KWERENDY ANALITYCZNE
-- ========================================================================


-- ------------------------------------------------------------------------
-- 2.1. Tabela akwizycji per wyspa promocyjna
-- ------------------------------------------------------------------------
-- Odnosi sie do: Tabela 6.1 raportu (akwizycja per wyspa)
-- Output: 15 wysp (classic_promo + fomo) z liczba pozyskanych klientow
--         i przychodem osobno dla yearly i monthly
-- ------------------------------------------------------------------------
WITH yearly_promos AS (
    SELECT
        amount AS promo_amount,
        first_seen,
        last_seen,
        DATEDIFF(last_seen, first_seen) + 1 AS dni_promocji,
        GREATEST(disc_before, disc_after) AS rabat_pct,
        promo_type
    FROM vw_promo_classification
    WHERE promo_type IN ('classic_promo', 'fomo')
),
client_first_txn AS (
    SELECT client_id, MIN(transaction_date) AS first_date
    FROM transactions
    GROUP BY client_id
),
yearly_acquisition AS (
    -- Nowi klienci yearly + przychod (pierwsza transakcja w cenie wyspy)
    SELECT
        yp.first_seen,
        COUNT(DISTINCT t.client_id) AS pozyskani_yearly,
        ROUND(SUM(t.amount), 2)     AS przychod_yearly
    FROM yearly_promos yp
    LEFT JOIN transactions t
      ON t.transaction_date BETWEEN yp.first_seen AND yp.last_seen
     AND t.amount = yp.promo_amount
    LEFT JOIN client_first_txn cft
      ON cft.client_id = t.client_id
     AND cft.first_date = t.transaction_date
    WHERE cft.client_id IS NOT NULL
    GROUP BY yp.first_seen
),
monthly_acquisition AS (
    -- Nowi klienci monthly w oknie wyspy + przychod
    SELECT
        yp.first_seen,
        COUNT(DISTINCT t.client_id) AS pozyskani_monthly,
        ROUND(SUM(t.amount), 2)     AS przychod_monthly
    FROM yearly_promos yp
    LEFT JOIN transactions t
      ON t.transaction_date BETWEEN yp.first_seen AND yp.last_seen
     AND t.amount < 250
    LEFT JOIN client_first_txn cft
      ON cft.client_id = t.client_id
     AND cft.first_date = t.transaction_date
    WHERE cft.client_id IS NOT NULL
    GROUP BY yp.first_seen
)
SELECT
    yp.first_seen      AS data_poczatkowa,
    yp.last_seen       AS data_koncowa,
    yp.dni_promocji,
    yp.promo_amount    AS cena_promo,
    yp.rabat_pct,
    COALESCE(ya.pozyskani_yearly, 0)  AS pozyskani_yearly,
    COALESCE(ya.przychod_yearly, 0)   AS przychod_yearly,
    COALESCE(ma.pozyskani_monthly, 0) AS pozyskani_monthly,
    COALESCE(ma.przychod_monthly, 0)  AS przychod_monthly
FROM yearly_promos yp
LEFT JOIN yearly_acquisition ya  ON ya.first_seen = yp.first_seen
LEFT JOIN monthly_acquisition ma ON ma.first_seen = yp.first_seen
ORDER BY yp.first_seen;


-- ------------------------------------------------------------------------
-- 2.2. Efekt halo - akwizycja monthly w dni promocyjne vs nie-promocyjne
-- ------------------------------------------------------------------------
-- Odnosi sie do: Wniosek A1 raportu (efekt halo 3.34x)
-- ------------------------------------------------------------------------
WITH all_dates AS (
    SELECT DISTINCT transaction_date AS d FROM transactions
),
yearly_promo_islands AS (
    SELECT first_seen, last_seen
    FROM vw_promo_classification
    WHERE promo_type IN ('classic_promo', 'fomo')
),
days_with_flag AS (
    SELECT
        ad.d,
        CASE WHEN EXISTS (
            SELECT 1 FROM yearly_promo_islands yp
            WHERE ad.d BETWEEN yp.first_seen AND yp.last_seen
        ) THEN 1 ELSE 0 END AS is_promo_day
    FROM all_dates ad
),
client_first_txn AS (
    SELECT client_id, MIN(transaction_date) AS first_date
    FROM transactions GROUP BY client_id
),
new_monthly_per_day AS (
    SELECT cft.first_date AS d, COUNT(*) AS new_clients
    FROM client_first_txn cft
    JOIN transactions t
      ON t.client_id = cft.client_id
     AND t.transaction_date = cft.first_date
    WHERE t.amount < 250
    GROUP BY cft.first_date
)
SELECT
    df.is_promo_day,
    COUNT(*)                                      AS dni,
    SUM(COALESCE(nmd.new_clients, 0))             AS lacznie_nowi_monthly,
    ROUND(AVG(COALESCE(nmd.new_clients, 0)), 2)   AS sr_nowi_monthly_per_dzien
FROM days_with_flag df
LEFT JOIN new_monthly_per_day nmd ON nmd.d = df.d
GROUP BY df.is_promo_day
ORDER BY df.is_promo_day;


-- ------------------------------------------------------------------------
-- 2.3. Retencja kohortowa monthly_sub - okno +/- 15 dni
-- ------------------------------------------------------------------------
-- Odnosi sie do: Sekcja 7.2 raportu (retencja monthly)
-- Uruchom 4 razy z roznymi parametrami N i CUTOFF:
--   N=1,  cutoff='2026-02-28'  (90 dni przed koncem okna danych)
--   N=3,  cutoff='2025-12-31'
--   N=6,  cutoff='2025-09-30'
--   N=12, cutoff='2025-03-31'
-- ------------------------------------------------------------------------
SET @N = 1;                            -- horyzont w miesiacach (1, 3, 6, 12)
SET @cutoff = '2026-02-28';            -- ostatnia data ktorej klient mial szanse dotrwac
SET @days = @N * 30;                   -- dni od pierwszej transakcji
SET @window = 15;                      -- okno tolerancji (+/- dni)

WITH client_first AS (
    SELECT client_id, MIN(transaction_date) AS first_date
    FROM transactions GROUP BY client_id
),
client_first_with_amount AS (
    SELECT
        cf.client_id,
        cf.first_date,
        (SELECT t.amount FROM transactions t
         WHERE t.client_id = cf.client_id AND t.transaction_date = cf.first_date
         ORDER BY t.amount LIMIT 1) AS first_amount
    FROM client_first cf
),
monthly_clients AS (
    SELECT * FROM client_first_with_amount WHERE first_amount < 250
),
monthly_cohorts AS (
    SELECT
        mc.*,
        CASE WHEN EXISTS (
            SELECT 1 FROM vw_promo_classification pc
            WHERE pc.promo_type IN ('classic_promo', 'fomo')
              AND mc.first_date BETWEEN pc.first_seen AND pc.last_seen
        ) THEN 'new_in_promo_day' ELSE 'organic' END AS cohort
    FROM monthly_clients mc
),
eligible AS (
    SELECT * FROM monthly_cohorts WHERE first_date <= @cutoff
),
retained AS (
    SELECT
        e.client_id,
        e.cohort,
        CASE WHEN EXISTS (
            SELECT 1 FROM transactions t
            WHERE t.client_id = e.client_id
              AND t.transaction_date > DATE_ADD(e.first_date, INTERVAL (@days - @window) DAY)
              AND t.transaction_date <= DATE_ADD(e.first_date, INTERVAL (@days + @window) DAY)
        ) THEN 1 ELSE 0 END AS is_retained
    FROM eligible e
)
SELECT
    cohort,
    COUNT(*)                                       AS kohorta_n,
    SUM(is_retained)                               AS zretencjonowani,
    ROUND(SUM(is_retained) * 100.0 / COUNT(*), 1)  AS retencja_pct
FROM retained
GROUP BY cohort
ORDER BY cohort;


-- ------------------------------------------------------------------------
-- 2.4. Retencja kohortowa yearly - okno +/- 30 dni
-- ------------------------------------------------------------------------
-- Odnosi sie do: Sekcja 7.3 raportu (retencja yearly)
-- Uruchom 4 razy z roznymi parametrami N i CUTOFF:
--   N=6,  cutoff='2025-09-30'
--   N=12, cutoff='2025-03-31'
--   N=18, cutoff='2024-09-30'
--   N=24, cutoff='2024-03-31'
-- ------------------------------------------------------------------------
SET @N = 12;
SET @cutoff = '2025-03-31';
SET @days = @N * 30;
SET @window = 30;

WITH client_first AS (
    SELECT client_id, MIN(transaction_date) AS first_date
    FROM transactions GROUP BY client_id
),
client_first_with_amount AS (
    SELECT
        cf.client_id,
        cf.first_date,
        (SELECT t.amount FROM transactions t
         WHERE t.client_id = cf.client_id AND t.transaction_date = cf.first_date
         ORDER BY t.amount LIMIT 1) AS first_amount
    FROM client_first cf
),
yearly_clients AS (
    SELECT * FROM client_first_with_amount WHERE first_amount >= 750
),
yearly_cohorts AS (
    SELECT
        yc.*,
        CASE WHEN EXISTS (
            SELECT 1 FROM vw_promo_classification pc
            WHERE pc.promo_type IN ('classic_promo', 'fomo')
              AND yc.first_date BETWEEN pc.first_seen AND pc.last_seen
              AND yc.first_amount = pc.amount
        ) THEN 'new_in_promo_day' ELSE 'organic' END AS cohort
    FROM yearly_clients yc
),
eligible AS (
    SELECT * FROM yearly_cohorts WHERE first_date <= @cutoff
),
retained AS (
    SELECT
        e.client_id,
        e.cohort,
        CASE WHEN EXISTS (
            SELECT 1 FROM transactions t
            WHERE t.client_id = e.client_id
              AND t.transaction_date > DATE_ADD(e.first_date, INTERVAL (@days - @window) DAY)
              AND t.transaction_date <= DATE_ADD(e.first_date, INTERVAL (@days + @window) DAY)
        ) THEN 1 ELSE 0 END AS is_retained
    FROM eligible e
)
SELECT
    cohort,
    COUNT(*)                                       AS kohorta_n,
    SUM(is_retained)                               AS zretencjonowani,
    ROUND(SUM(is_retained) * 100.0 / COUNT(*), 1)  AS retencja_pct
FROM retained
GROUP BY cohort
ORDER BY cohort;


-- ------------------------------------------------------------------------
-- 2.5. Statystyki zycia klienta per kohorta (avg txn, lifespan, revenue)
-- ------------------------------------------------------------------------
-- Odnosi sie do: Tabela "Statystyki zycia" w sekcjach 7.2 i 7.3 raportu
-- Parametr: ustaw segment_filter wedlug potrzeby:
--   monthly_sub: amount < 250
--   yearly:      amount >= 750
-- ------------------------------------------------------------------------
WITH client_first AS (
    SELECT client_id, MIN(transaction_date) AS first_date
    FROM transactions GROUP BY client_id
),
client_first_with_amount AS (
    SELECT
        cf.client_id,
        cf.first_date,
        (SELECT t.amount FROM transactions t
         WHERE t.client_id = cf.client_id AND t.transaction_date = cf.first_date
         ORDER BY t.amount LIMIT 1) AS first_amount
    FROM client_first cf
),
filtered_clients AS (
    -- ZMIEN W ZALEZNOSCI OD SEGMENTU:
    SELECT * FROM client_first_with_amount WHERE first_amount < 250  -- monthly_sub
    -- SELECT * FROM client_first_with_amount WHERE first_amount >= 750  -- yearly
),
cohorts AS (
    SELECT
        fc.*,
        CASE WHEN EXISTS (
            SELECT 1 FROM vw_promo_classification pc
            WHERE pc.promo_type IN ('classic_promo', 'fomo')
              AND fc.first_date BETWEEN pc.first_seen AND pc.last_seen
        ) THEN 'new_in_promo_day' ELSE 'organic' END AS cohort
    FROM filtered_clients fc
),
client_stats AS (
    SELECT
        c.client_id,
        c.cohort,
        (SELECT COUNT(*) FROM transactions t WHERE t.client_id = c.client_id) AS total_txn,
        (SELECT DATEDIFF(MAX(transaction_date), c.first_date)
         FROM transactions t WHERE t.client_id = c.client_id) AS lifespan_days,
        (SELECT SUM(amount) FROM transactions t WHERE t.client_id = c.client_id) AS total_revenue
    FROM cohorts c
)
SELECT
    cohort,
    COUNT(*)                              AS n,
    ROUND(AVG(total_txn), 2)              AS avg_txn,
    ROUND(AVG(lifespan_days), 0)          AS avg_lifespan_days,
    ROUND(AVG(total_revenue), 2)          AS avg_revenue,
    ROUND(SUM(total_revenue), 2)          AS total_revenue
FROM client_stats
GROUP BY cohort
ORDER BY cohort;


-- ------------------------------------------------------------------------
-- 2.6. Wplyw podwyzki na retencje - Era 2 -> Era 3 (2025-10-01)
-- ------------------------------------------------------------------------
-- Odnosi sie do: Sekcja 8.1 raportu
-- ------------------------------------------------------------------------
WITH last_txn_before_e3 AS (
    -- Ostatnia transakcja kazdego klienta przed Era 3
    SELECT client_id, MAX(transaction_date) AS last_date_before_e3
    FROM transactions WHERE transaction_date < '2025-10-01'
    GROUP BY client_id
),
aktywni_e2 AS (
    -- Klienci Ery 2 monthly_sub aktywni przed podwyzka
    -- (ostatnia transakcja w oknie 35 dni przed 2025-10-01)
    SELECT c.client_id
    FROM vw_fct_clients_v1 c
    JOIN last_txn_before_e3 l USING (client_id)
    WHERE c.acquisition_era = 'Era_2'
      AND c.acquisition_segment = 'monthly_sub'
      AND l.last_date_before_e3 >= '2025-08-27'
),
pierwsza_akcja_e3 AS (
    -- Pierwsza akcja kazdego aktywnego klienta w Erze 3
    SELECT
        a.client_id,
        (SELECT t.amount FROM transactions t
         WHERE t.client_id = a.client_id AND t.transaction_date >= '2025-10-01'
         ORDER BY t.transaction_date LIMIT 1) AS pierwsza_amount_e3
    FROM aktywni_e2 a
)
SELECT
    CASE
        WHEN pierwsza_amount_e3 IS NULL         THEN '1. CHURN - nie pojawil sie w E3'
        WHEN pierwsza_amount_e3 = 169           THEN '2. GRANDFATHERED 169'
        WHEN pierwsza_amount_e3 IN (199, 249)   THEN '3. UPGRADE na nowa cene'
        ELSE                                         '4. INNE (rabat lub zmiana planu)'
    END AS status,
    COUNT(*) AS n,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM pierwsza_akcja_e3
GROUP BY 1
ORDER BY 1;


-- ------------------------------------------------------------------------
-- 2.7. Wplyw podwyzki na retencje - Era 1 -> Era 2 (2024-09-01)
-- ------------------------------------------------------------------------
-- Odnosi sie do: Sekcja 8.2 raportu
-- ------------------------------------------------------------------------
WITH ceny_era1 AS (
    -- Wszystkie ceny monthly_sub uzywane w Erze 1
    SELECT DISTINCT amount
    FROM transactions
    WHERE amount < 250 AND transaction_date < '2024-09-01'
),
last_txn_before_e2 AS (
    SELECT client_id, MAX(transaction_date) AS last_date_before_e2
    FROM transactions WHERE transaction_date < '2024-09-01'
    GROUP BY client_id
),
aktywni_e1 AS (
    SELECT c.client_id
    FROM vw_fct_clients_v1 c
    JOIN last_txn_before_e2 l USING (client_id)
    WHERE c.acquisition_era = 'Era_1'
      AND c.acquisition_segment = 'monthly_sub'
      AND l.last_date_before_e2 >= '2024-07-28'
),
pierwsza_akcja_e2 AS (
    SELECT
        a.client_id,
        (SELECT t.amount FROM transactions t
         WHERE t.client_id = a.client_id AND t.transaction_date >= '2024-09-01'
         ORDER BY t.transaction_date LIMIT 1) AS pierwsza_amount_e2
    FROM aktywni_e1 a
)
SELECT
    CASE
        WHEN pierwsza_amount_e2 IS NULL                            THEN '1. CHURN - nie pojawil sie w E2'
        WHEN pierwsza_amount_e2 IN (SELECT amount FROM ceny_era1)  THEN '2. GRANDFATHERED (cena z Ery 1)'
        WHEN pierwsza_amount_e2 >= 169 AND pierwsza_amount_e2 < 250 THEN '3. UPGRADE na cene Ery 2 (169+)'
        WHEN pierwsza_amount_e2 >= 250 AND pierwsza_amount_e2 < 750 THEN '4. ZMIANA NA COURSE_PACK'
        WHEN pierwsza_amount_e2 >= 750                              THEN '5. ZMIANA NA YEARLY'
        ELSE                                                             '6. INNE'
    END AS status,
    COUNT(*) AS n,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM pierwsza_akcja_e2
GROUP BY 1
ORDER BY 1;


-- ========================================================================
-- SEKCJA 3: KWERENDY WALIDACYJNE
-- ========================================================================


-- ------------------------------------------------------------------------
-- 3.1. Sygnatura switch vs displacement - dowod liczbowy
-- ------------------------------------------------------------------------
-- Odnosi sie do: Sekcja 5 raportu (Sygnatura strategii cenowej KDS)
-- Liczy dni wspolnej sprzedazy starej i nowej ceny dla kazdej tranzycji
-- ------------------------------------------------------------------------
WITH transitions AS (
    -- Hardcoded pary cen katalogowych per segment (zidentyfikowane analiza)
    SELECT 'yearly'      AS segment, 990  AS old_price, 1799 AS new_price
    UNION ALL SELECT 'yearly',      1799, 1999
    UNION ALL SELECT 'monthly_sub',   89,   99
    UNION ALL SELECT 'monthly_sub',   99,  169
    UNION ALL SELECT 'monthly_sub',  169,  199
    UNION ALL SELECT 'monthly_sub',  199,  249
)
SELECT
    t.segment,
    CONCAT(t.old_price, ' -> ', t.new_price) AS transition,
    (SELECT MIN(transaction_date) FROM transactions
     WHERE amount = t.new_price) AS pierwsze_pojawienie_nowej,
    (SELECT MAX(transaction_date) FROM transactions
     WHERE amount = t.old_price) AS ostatnie_pojawienie_starej,
    (SELECT COUNT(DISTINCT old_t.transaction_date)
     FROM transactions old_t
     INNER JOIN transactions new_t
       ON old_t.transaction_date = new_t.transaction_date
     WHERE old_t.amount = t.old_price
       AND new_t.amount = t.new_price) AS dni_wspolnej_sprzedazy
FROM transitions t
ORDER BY t.segment, t.old_price;


-- ------------------------------------------------------------------------
-- 3.2. TOP 3 cen monthly_sub per miesiac z flaga had_yearly_promo
-- ------------------------------------------------------------------------
-- Odnosi sie do: Walidacja interpretacji er cenowych monthly_sub
-- ------------------------------------------------------------------------
WITH monthly_sub_amounts AS (
    SELECT
        DATE_FORMAT(transaction_date,'%Y-%m') AS `month`,
        amount,
        COUNT(*) AS txn_cnt,
        SUM(COUNT(*)) OVER (
            PARTITION BY DATE_FORMAT(transaction_date,'%Y-%m')
        ) AS total_monthly_txn
    FROM transactions
    WHERE amount < 250
    GROUP BY 1, 2
),
rank_by_month AS (
    SELECT
        *,
        RANK() OVER (
            PARTITION BY `month`
            ORDER BY txn_cnt DESC
        ) AS ranking,
        CASE WHEN EXISTS (
            SELECT 1 FROM vw_promo_classification pc
            WHERE pc.promo_type IN ('classic_promo', 'fomo')
              AND DATE_FORMAT(pc.first_seen, '%Y-%m') = monthly_sub_amounts.`month`
        ) THEN 1 ELSE 0 END AS had_yearly_promo
    FROM monthly_sub_amounts
)
SELECT
    ranking,
    `month`,
    amount,
    txn_cnt,
    ROUND(txn_cnt / total_monthly_txn, 2) * 100.0 AS monthly_share_pct,
    total_monthly_txn,
    had_yearly_promo
FROM rank_by_month
WHERE ranking <= 3
ORDER BY `month`, ranking;


-- ------------------------------------------------------------------------
-- 3.3. Walidacje liczb klientow (sanity checks)
-- ------------------------------------------------------------------------

-- Liczba klientow w fct_clients_v1 (oczekiwane: 1057)
SELECT COUNT(*) AS klientow_total FROM vw_fct_clients_v1;

-- Liczba unikalnych klientow w transactions (powinno byc tyle samo)
SELECT COUNT(DISTINCT client_id) AS unique_clients FROM transactions;

-- Rozklad era x segment w fct_clients_v1
SELECT
    acquisition_era,
    acquisition_segment,
    COUNT(*) AS n
FROM vw_fct_clients_v1
GROUP BY 1, 2
ORDER BY 1, 2;

-- Rozklad acquisition_category w fct_clients_v15
SELECT
    acquisition_category,
    COUNT(*) AS n
FROM vw_fct_clients_v15
GROUP BY 1
ORDER BY n DESC;

-- Liczba kategorii w vw_promo_classification
SELECT
    promo_type,
    COUNT(*) AS n
FROM vw_promo_classification
GROUP BY promo_type
ORDER BY n DESC;


-- ========================================================================
-- KONIEC PLIKU
-- ========================================================================
