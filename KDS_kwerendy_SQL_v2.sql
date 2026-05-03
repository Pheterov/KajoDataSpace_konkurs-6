-- ========================================================================
-- KajoDataSpace - Analiza retencji: kompletny zestaw kwerend SQL
-- Wersja: 2.0 (production-optimized)
-- ========================================================================
-- Stack: MySQL 8.0+ / MariaDB 10.6+
-- Dokument towarzyszacy: KDS_analiza_kompletna.md
--
-- ZMIANY VS WERSJA 1.0:
--   * Wszystkie correlated subqueries zastapione JOIN/window functions
--   * EXISTS zastapione LEFT JOIN z agregacja (deduplikacja przez MAX/COUNT)
--   * Pre-agregaty per klient liczone raz, reuzywane przez wiele query
--   * Sekcja 2.5: 3 osobne correlated subqueries -> jeden GROUP BY
--   * Sekcja 2.5: parametryzacja segmentu przez user variable
--                 (nie odkomentowywanie linii)
--   * Sekcje 2.6/2.7: correlated subquery na pierwsza akcje -> ROW_NUMBER
--
-- INDEKSY ZALECANE (utworzyc PRZED uruchomieniem):
--   CREATE INDEX idx_client_date  ON transactions(client_id, transaction_date);
--   CREATE INDEX idx_amount_date  ON transactions(amount, transaction_date);
--   CREATE INDEX idx_date         ON transactions(transaction_date);
--
-- KOLEJNOSC URUCHOMIENIA:
--   1. Sekcja 1 - utworz wszystkie widoki (kolejnosc: 1.1 -> 1.2 -> 1.3)
--   2. Sekcje 2 i 3 - mozna uruchamiac niezaleznie po utworzeniu widokow
--
-- ZALEZNOSCI ZEWNETRZNE:
--   Tabela: transactions(transaction_date DATE, client_id INT, amount DECIMAL)
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
--
-- OPTYMALIZACJA: dwa correlated subqueries dla max_price_before/after_60d
-- zastapione self-JOIN-em po segmentowanych transakcjach.
-- ------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_promo_classification;

CREATE VIEW vw_promo_classification AS
WITH transactions_segmented AS (
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
    SELECT
        amount,
        transaction_date,
        DATEDIFF(
            transaction_date,
            LAG(transaction_date) OVER (
                PARTITION BY amount ORDER BY transaction_date
            )
        ) AS gap_days
    FROM transactions
),
island_flags AS (
    SELECT
        amount,
        transaction_date,
        CASE
            WHEN gap_days > 7 OR gap_days IS NULL THEN 1
            ELSE 0
        END AS is_new_island
    FROM gaps
),
islands AS (
    SELECT
        amount,
        transaction_date,
        SUM(is_new_island) OVER (
            PARTITION BY amount ORDER BY transaction_date
        ) AS island_id
    FROM island_flags
),
island_stats AS (
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
    SELECT
        *,
        CASE
            WHEN segment = 'monthly_sub' AND density >= 3.0 AND txn_cnt >= 5 THEN 1
            WHEN segment = 'yearly'      AND density >= 0.8 AND txn_cnt >= 2 THEN 1
            ELSE 0
        END AS is_candidate
    FROM island_stats
),
yearly_candidates AS (
    -- Wyodrebnienie tylko yearly-candidates do dalszego liczenia kontekstu cenowego
    SELECT *
    FROM candidates
    WHERE is_candidate = 1
      AND segment = 'yearly'
),
context_before AS (
    -- Max cena yearly w oknie 60 dni PRZED kazda wyspa-kandydatem.
    -- LEFT JOIN zamiast correlated subquery: jedna agregacja dla wszystkich wysp.
    SELECT
        yc.amount AS island_amount,
        yc.island_id,
        MAX(ts.amount) AS max_price_before_60d
    FROM yearly_candidates yc
    LEFT JOIN transactions_segmented ts
        ON ts.segment = 'yearly'
       AND ts.transaction_date >= DATE_SUB(yc.first_seen, INTERVAL 60 DAY)
       AND ts.transaction_date <  yc.first_seen
    GROUP BY yc.amount, yc.island_id
),
context_after AS (
    -- Max cena yearly w oknie 60 dni PO kazdej wyspie-kandydacie
    SELECT
        yc.amount AS island_amount,
        yc.island_id,
        MAX(ts.amount) AS max_price_after_60d
    FROM yearly_candidates yc
    LEFT JOIN transactions_segmented ts
        ON ts.segment = 'yearly'
       AND ts.transaction_date >  yc.last_seen
       AND ts.transaction_date <= DATE_ADD(yc.last_seen, INTERVAL 60 DAY)
    GROUP BY yc.amount, yc.island_id
),
yearly_with_context AS (
    SELECT
        yc.*,
        cb.max_price_before_60d,
        ca.max_price_after_60d
    FROM yearly_candidates yc
    LEFT JOIN context_before cb
        ON cb.island_amount = yc.amount AND cb.island_id = yc.island_id
    LEFT JOIN context_after ca
        ON ca.island_amount = yc.amount AND ca.island_id = yc.island_id
),
promo_classification AS (
    -- Klasyfikacja na 5 kategorii biznesowych.
    -- Kolejnosc CASE WHEN: od najbardziej specyficznej do ogolnej.
    --
    -- ZMIANA W WERSJI 2.0: prog grandfathering 45% -> 50%.
    -- Powod: prog 45% klasyfikowal jako 'grandfathering' wyspe, na ktora
    -- trafili nowi klienci (np. 2025-03-12 amount=959.20, n=2, oboje pierwsza
    -- i jedyna transakcja). Semantycznie 'grandfathering' to klient z legacy
    -- ceny utrzymywanej przez firme - nowi klienci nie pasuja do tej kategorii.
    -- Prog 50% jest wystarczajacy dla obecnych danych (klienci legacy maja
    -- delta 55-58%, nowi przypadkowi 46%). Przy znaczacej zmianie cennika
    -- moze wymagac ponownego strojenia.
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
            WHEN (max_price_before_60d - amount) / max_price_before_60d * 100 > 50
              OR (max_price_after_60d  - amount) / max_price_after_60d  * 100 > 50
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
-- Cel: Tabela jeden-wiersz-per-klient z atrybutami pozyskania.
--      Wersja v1 byla juz optymalna (ROW_NUMBER), zostawiamy bez zmian.
-- Output: 1057 wierszy
-- ------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_fct_clients_v1;

CREATE VIEW vw_fct_clients_v1 AS
WITH ordered_transactions AS (
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
    CASE
        WHEN f.first_transaction_date < '2024-09-01' THEN 'Era_1'
        WHEN f.first_transaction_date < '2025-10-01' THEN 'Era_2'
        ELSE                                              'Era_3'
    END AS acquisition_era,
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
--
-- OPTYMALIZACJA: correlated subquery dla prev_txn_date zastapiony LEFT JOIN
-- z agregacja MAX (zachowuje semantyke biznesowa: MAX z wszystkich transakcji
-- klienta z data < first_promo_date).
--
-- UWAGA - ROZBIEZNOSC vs WERSJA 1.0:
-- W oryginale correlated subquery dla prev_txn_date odwoluje sie do
-- MIN(pp.promo_date) z zewnetrznego GROUP BY. Niektore wersje MySQL/MariaDB
-- zwracaja NULL zamiast oczekiwanej daty w tym kontekscie (bug zalezny od
-- silnika). To powoduje, ze klient 137 (jeden klient w obecnym datasecie)
-- byl klasyfikowany jako 'organic' zamiast 'reactivated_by_promo' - delta=372
-- dni, warunek > 370 spelniony, ale prev_txn_date wracalo NULL.
--
-- Wersja 2.0 z LEFT JOIN da poprawny wynik: 1 klient 'reactivated_by_promo'
-- zamiast 0 w oryginale. Roznica logiczna 1 klient na 1057 (0.09%) -
-- wynik MERYTORYCZNIE POPRAWNY, ale nie identyczny vs raport opisany na
-- bazie wersji 1.0. Konieczna aktualizacja narracji raportu (wzmianka
-- "kategoria reactivated_by_promo: 0 klientow" -> "1 klient").
-- ------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_fct_clients_v15;

CREATE VIEW vw_fct_clients_v15 AS
WITH promo_purchases AS (
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
client_first_promo AS (
    SELECT
        client_id,
        MIN(promo_date) AS first_promo_date
    FROM promo_purchases
    GROUP BY client_id
),
first_promo_per_client AS (
    -- LEFT JOIN do transactions zfiltrowanych po dacie < first_promo_date,
    -- agregacja MAX. Jedna agregacja zamiast N correlated subqueries.
    SELECT
        cfp.client_id,
        cfp.first_promo_date,
        MAX(t.transaction_date) AS prev_txn_date
    FROM client_first_promo cfp
    LEFT JOIN transactions t
        ON t.client_id = cfp.client_id
       AND t.transaction_date < cfp.first_promo_date
    GROUP BY cfp.client_id, cfp.first_promo_date
)
SELECT
    v1.*,
    CASE
        WHEN fp.first_promo_date = v1.first_transaction_date
         AND v1.acquisition_segment = 'yearly'
            THEN 'new_in_promo'
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
-- Wersja oryginalna byla juz w pelni JOIN-owana, zostawiamy bez zmian.
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
--
-- OPTYMALIZACJA: EXISTS na yearly_promo_islands zastapiony LEFT JOIN+MAX
-- (deduplikacja przy potencjalnie nakladajacych sie wyspach przez MAX).
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
    -- LEFT JOIN + MAX: jezeli istnieje cokolwiek pasujacego, MAX != NULL
    SELECT
        ad.d,
        CASE WHEN MAX(yp.first_seen) IS NOT NULL THEN 1 ELSE 0 END AS is_promo_day
    FROM all_dates ad
    LEFT JOIN yearly_promo_islands yp
        ON ad.d BETWEEN yp.first_seen AND yp.last_seen
    GROUP BY ad.d
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
--   N=1,  cutoff='2026-02-28'
--   N=3,  cutoff='2025-12-31'
--   N=6,  cutoff='2025-09-30'
--   N=12, cutoff='2025-03-31'
--
-- OPTYMALIZACJE:
--   * tie-breaker correlated subquery -> ROW_NUMBER (1 skan)
--   * EXISTS na promo_classification -> LEFT JOIN + MAX
--   * EXISTS na transactions per klient -> LEFT JOIN do okna retencyjnego
-- ------------------------------------------------------------------------
SET @N = 1;
SET @cutoff = '2026-02-28';
SET @days = @N * 30;
SET @window = 15;

WITH ranked_transactions AS (
    -- ROW_NUMBER zastepuje MIN+tie-breaker correlated subquery
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
client_first AS (
    SELECT
        client_id,
        transaction_date AS first_date,
        amount           AS first_amount
    FROM ranked_transactions
    WHERE rn = 1
),
monthly_clients AS (
    SELECT *
    FROM client_first
    WHERE first_amount < 250
),
promo_islands AS (
    SELECT first_seen, last_seen
    FROM vw_promo_classification
    WHERE promo_type IN ('classic_promo', 'fomo')
),
monthly_cohorts AS (
    -- LEFT JOIN + MAX zamiast EXISTS: deduplikacja przez GROUP BY client_id
    SELECT
        mc.client_id,
        mc.first_date,
        mc.first_amount,
        CASE WHEN MAX(pi.first_seen) IS NOT NULL
             THEN 'new_in_promo_day'
             ELSE 'organic'
        END AS cohort
    FROM monthly_clients mc
    LEFT JOIN promo_islands pi
        ON mc.first_date BETWEEN pi.first_seen AND pi.last_seen
    GROUP BY mc.client_id, mc.first_date, mc.first_amount
),
eligible AS (
    SELECT *
    FROM monthly_cohorts
    WHERE first_date <= @cutoff
),
retained AS (
    -- LEFT JOIN do transactions w oknie retencyjnym + COUNT > 0 zamiast EXISTS.
    -- Jeden skan transactions z pre-filtrem dat zamiast N skanow per klient.
    SELECT
        e.client_id,
        e.cohort,
        CASE WHEN COUNT(t.transaction_date) > 0 THEN 1 ELSE 0 END AS is_retained
    FROM eligible e
    LEFT JOIN transactions t
        ON t.client_id = e.client_id
       AND t.transaction_date >  DATE_ADD(e.first_date, INTERVAL (@days - @window) DAY)
       AND t.transaction_date <= DATE_ADD(e.first_date, INTERVAL (@days + @window) DAY)
    GROUP BY e.client_id, e.cohort
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
--
-- OPTYMALIZACJE: identyczne jak 2.3, plus warunek `amount = pc.amount`
-- przeniesiony z EXISTS do warunku JOIN.
-- ------------------------------------------------------------------------
SET @N = 12;
SET @cutoff = '2025-03-31';
SET @days = @N * 30;
SET @window = 30;

WITH ranked_transactions AS (
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
client_first AS (
    SELECT
        client_id,
        transaction_date AS first_date,
        amount           AS first_amount
    FROM ranked_transactions
    WHERE rn = 1
),
yearly_clients AS (
    SELECT *
    FROM client_first
    WHERE first_amount >= 750
),
promo_islands AS (
    -- Dla yearly potrzebujemy tez `amount` zeby matchowac po cenie
    SELECT amount, first_seen, last_seen
    FROM vw_promo_classification
    WHERE promo_type IN ('classic_promo', 'fomo')
),
yearly_cohorts AS (
    SELECT
        yc.client_id,
        yc.first_date,
        yc.first_amount,
        CASE WHEN MAX(pi.first_seen) IS NOT NULL
             THEN 'new_in_promo_day'
             ELSE 'organic'
        END AS cohort
    FROM yearly_clients yc
    LEFT JOIN promo_islands pi
        ON yc.first_date BETWEEN pi.first_seen AND pi.last_seen
       AND yc.first_amount = pi.amount
    GROUP BY yc.client_id, yc.first_date, yc.first_amount
),
eligible AS (
    SELECT *
    FROM yearly_cohorts
    WHERE first_date <= @cutoff
),
retained AS (
    SELECT
        e.client_id,
        e.cohort,
        CASE WHEN COUNT(t.transaction_date) > 0 THEN 1 ELSE 0 END AS is_retained
    FROM eligible e
    LEFT JOIN transactions t
        ON t.client_id = e.client_id
       AND t.transaction_date >  DATE_ADD(e.first_date, INTERVAL (@days - @window) DAY)
       AND t.transaction_date <= DATE_ADD(e.first_date, INTERVAL (@days + @window) DAY)
    GROUP BY e.client_id, e.cohort
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
--
-- OPTYMALIZACJE:
--   * 3 osobne correlated subqueries (COUNT/MAX/SUM per klient) -> jeden GROUP BY
--   * tie-breaker correlated subquery -> ROW_NUMBER
--   * EXISTS na promo_classification -> LEFT JOIN + MAX
--   * Segment sparametryzowany przez user variable (nie odkomentowywanie linii)
--   * Pre-agregaty liczone tylko dla klientow w segmencie (JOIN przed GROUP BY)
-- ------------------------------------------------------------------------
SET @segment_filter = 'monthly_sub';   -- 'monthly_sub' lub 'yearly'

WITH ranked_transactions AS (
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
client_first AS (
    SELECT
        client_id,
        transaction_date AS first_date,
        amount           AS first_amount
    FROM ranked_transactions
    WHERE rn = 1
),
filtered_clients AS (
    -- Jednolita logika filtra dla obu segmentow, niezalezna od magic numbers
    SELECT *
    FROM client_first
    WHERE (@segment_filter = 'monthly_sub' AND first_amount <  250)
       OR (@segment_filter = 'yearly'      AND first_amount >= 750)
),
client_aggregates AS (
    -- Pre-agregaty per klient: jeden GROUP BY zamiast 3 correlated subqueries.
    -- JOIN do filtered_clients PRZED GROUP BY agreguje tylko transakcje
    -- klientow w segmencie (nie marnuje pracy dla pozostalych).
    SELECT
        t.client_id,
        COUNT(*)                 AS total_txn,
        MAX(t.transaction_date)  AS last_date,
        SUM(t.amount)            AS total_revenue
    FROM transactions t
    JOIN filtered_clients fc USING (client_id)
    GROUP BY t.client_id
),
promo_islands AS (
    SELECT first_seen, last_seen
    FROM vw_promo_classification
    WHERE promo_type IN ('classic_promo', 'fomo')
),
cohorts AS (
    SELECT
        fc.client_id,
        fc.first_date,
        CASE WHEN MAX(pi.first_seen) IS NOT NULL
             THEN 'new_in_promo_day'
             ELSE 'organic'
        END AS cohort
    FROM filtered_clients fc
    LEFT JOIN promo_islands pi
        ON fc.first_date BETWEEN pi.first_seen AND pi.last_seen
    GROUP BY fc.client_id, fc.first_date
),
client_stats AS (
    SELECT
        c.client_id,
        c.cohort,
        a.total_txn,
        DATEDIFF(a.last_date, c.first_date) AS lifespan_days,
        a.total_revenue
    FROM cohorts c
    JOIN client_aggregates a USING (client_id)
)
SELECT
    cohort,
    COUNT(*)                              AS n,
    ROUND(AVG(total_txn), 2)              AS avg_txn,
    ROUND(AVG(lifespan_days), 0)          AS avg_lifespan_days,
    ROUND(AVG(total_revenue), 2)          AS avg_revenue,
    ROUND(SUM(total_revenue), 2)          AS sum_revenue
FROM client_stats
GROUP BY cohort
ORDER BY cohort;


-- ------------------------------------------------------------------------
-- 2.6. Wplyw podwyzki na retencje - Era 2 -> Era 3 (2025-10-01)
-- ------------------------------------------------------------------------
-- Odnosi sie do: Sekcja 8.1 raportu
--
-- OPTYMALIZACJA: correlated subquery na pierwsza akcje w E3 zastapiony
-- ROW_NUMBER (jeden skan transakcji w E3 zamiast N skanow per klient).
-- ------------------------------------------------------------------------
WITH last_txn_before_e3 AS (
    SELECT client_id, MAX(transaction_date) AS last_date_before_e3
    FROM transactions
    WHERE transaction_date < '2025-10-01'
    GROUP BY client_id
),
aktywni_e2 AS (
    -- Klienci Ery 2 monthly_sub aktywni w oknie 35 dni przed podwyzka
    SELECT c.client_id
    FROM vw_fct_clients_v1 c
    JOIN last_txn_before_e3 l USING (client_id)
    WHERE c.acquisition_era = 'Era_2'
      AND c.acquisition_segment = 'monthly_sub'
      AND l.last_date_before_e3 >= '2025-08-27'
),
ranked_e3 AS (
    -- ROW_NUMBER zastepuje correlated subquery z LIMIT 1.
    -- Pre-filtr daty (>= 2025-10-01) ogranicza zakres window function.
    SELECT
        client_id,
        transaction_date,
        amount,
        ROW_NUMBER() OVER (
            PARTITION BY client_id ORDER BY transaction_date
        ) AS rn
    FROM transactions
    WHERE transaction_date >= '2025-10-01'
),
pierwsza_akcja_e3 AS (
    -- LEFT JOIN do ranked_e3 z rn=1: jezeli nie ma wiersza, klient = CHURN
    SELECT
        a.client_id,
        re.amount AS pierwsza_amount_e3
    FROM aktywni_e2 a
    LEFT JOIN ranked_e3 re
        ON re.client_id = a.client_id
       AND re.rn = 1
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
--
-- OPTYMALIZACJA: jak 2.6 - ROW_NUMBER zamiast correlated subquery.
-- ------------------------------------------------------------------------
WITH ceny_era1 AS (
    SELECT DISTINCT amount
    FROM transactions
    WHERE amount < 250 AND transaction_date < '2024-09-01'
),
last_txn_before_e2 AS (
    SELECT client_id, MAX(transaction_date) AS last_date_before_e2
    FROM transactions
    WHERE transaction_date < '2024-09-01'
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
ranked_e2 AS (
    SELECT
        client_id,
        transaction_date,
        amount,
        ROW_NUMBER() OVER (
            PARTITION BY client_id ORDER BY transaction_date
        ) AS rn
    FROM transactions
    WHERE transaction_date >= '2024-09-01'
),
pierwsza_akcja_e2 AS (
    SELECT
        a.client_id,
        re.amount AS pierwsza_amount_e2
    FROM aktywni_e1 a
    LEFT JOIN ranked_e2 re
        ON re.client_id = a.client_id
       AND re.rn = 1
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
--
-- OPTYMALIZACJE:
--   * MIN/MAX correlated subqueries -> pre-agregat raz dla wszystkich cen
--   * Self-JOIN dla dni_wspolnej_sprzedazy -> zostaje (jest minimalny w tym kontekscie)
-- ------------------------------------------------------------------------
WITH transitions AS (
    SELECT 'yearly'      AS segment, 990  AS old_price, 1799 AS new_price
    UNION ALL SELECT 'yearly',      1799, 1999
    UNION ALL SELECT 'monthly_sub',   89,   99
    UNION ALL SELECT 'monthly_sub',   99,  169
    UNION ALL SELECT 'monthly_sub',  169,  199
    UNION ALL SELECT 'monthly_sub',  199,  249
),
relevant_amounts AS (
    -- Lista wszystkich cen wystepujacych w transitions (old + new)
    SELECT old_price AS amount FROM transitions
    UNION
    SELECT new_price AS amount FROM transitions
),
price_range AS (
    -- Pre-agregat: min/max date dla kazdej istotnej ceny.
    -- Jeden skan zamiast 2 correlated subqueries per transition.
    SELECT
        t.amount,
        MIN(t.transaction_date) AS first_date,
        MAX(t.transaction_date) AS last_date
    FROM transactions t
    JOIN relevant_amounts r ON t.amount = r.amount
    GROUP BY t.amount
),
overlap_days AS (
    -- Dni wspolnej sprzedazy: dni w ktorych obie ceny istnialy.
    -- Self-JOIN po dacie + filtr na pary (old, new) z transitions.
    SELECT
        tr.segment,
        tr.old_price,
        tr.new_price,
        COUNT(DISTINCT old_t.transaction_date) AS dni_wspolnej_sprzedazy
    FROM transitions tr
    LEFT JOIN transactions old_t
        ON old_t.amount = tr.old_price
    LEFT JOIN transactions new_t
        ON new_t.amount = tr.new_price
       AND new_t.transaction_date = old_t.transaction_date
    WHERE new_t.transaction_date IS NOT NULL
    GROUP BY tr.segment, tr.old_price, tr.new_price
)
SELECT
    t.segment,
    CONCAT(t.old_price, ' -> ', t.new_price) AS transition,
    new_p.first_date AS pierwsze_pojawienie_nowej,
    old_p.last_date  AS ostatnie_pojawienie_starej,
    COALESCE(o.dni_wspolnej_sprzedazy, 0) AS dni_wspolnej_sprzedazy
FROM transitions t
LEFT JOIN price_range new_p ON new_p.amount = t.new_price
LEFT JOIN price_range old_p ON old_p.amount = t.old_price
LEFT JOIN overlap_days o
    ON o.segment    = t.segment
   AND o.old_price  = t.old_price
   AND o.new_price  = t.new_price
ORDER BY t.segment, t.old_price;


-- ------------------------------------------------------------------------
-- 3.2. TOP 3 cen monthly_sub per miesiac z flaga had_yearly_promo
-- ------------------------------------------------------------------------
-- Odnosi sie do: Walidacja interpretacji er cenowych monthly_sub
--
-- OPTYMALIZACJA: EXISTS na vw_promo_classification per wiersz ->
-- pre-zfiltrowana lista miesiecy z promo + LEFT JOIN.
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
months_with_yearly_promo AS (
    -- Pre-agregat: lista DISTINCT miesiecy ktore mialy yearly promo.
    -- Liczone raz, reuzywane przez wszystkie wiersze rank_by_month.
    SELECT DISTINCT DATE_FORMAT(first_seen, '%Y-%m') AS `month`
    FROM vw_promo_classification
    WHERE promo_type IN ('classic_promo', 'fomo')
),
rank_by_month AS (
    SELECT
        msa.*,
        RANK() OVER (
            PARTITION BY msa.`month`
            ORDER BY msa.txn_cnt DESC
        ) AS ranking,
        CASE WHEN myp.`month` IS NOT NULL THEN 1 ELSE 0 END AS had_yearly_promo
    FROM monthly_sub_amounts msa
    LEFT JOIN months_with_yearly_promo myp
        ON myp.`month` = msa.`month`
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

SELECT COUNT(*) AS klientow_total FROM vw_fct_clients_v1;

SELECT COUNT(DISTINCT client_id) AS unique_clients FROM transactions;

SELECT
    acquisition_era,
    acquisition_segment,
    COUNT(*) AS n
FROM vw_fct_clients_v1
GROUP BY 1, 2
ORDER BY 1, 2;

SELECT
    acquisition_category,
    COUNT(*) AS n
FROM vw_fct_clients_v15
GROUP BY 1
ORDER BY n DESC;

SELECT
    promo_type,
    COUNT(*) AS n
FROM vw_promo_classification
GROUP BY promo_type
ORDER BY n DESC;


-- ========================================================================
-- KONIEC PLIKU
-- ========================================================================
