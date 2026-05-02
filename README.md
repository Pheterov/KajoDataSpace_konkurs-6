# Analiza retencji klientów KajoDataSpace 
## Wpływ promocji, standardowych cen i podwyżek na zachowanie klientów

**Autor:** Piotr Rzepka  
**Stack:** MySQL 8+ (kwerendy), DuckDB (walidacja)  
**Zakres danych:** 2023-11-05 do 2026-03-31, 4 227 transakcji, 1 057 unikalnych klientów  
**Wersja dokumentu:** 02.05.2026

---

## SPIS TREŚCI

1. [Pytanie badawcze](#1-pytanie-badawcze)
2. [Metodologia — przegląd](#2-metodologia--przegląd)
3. [Etap 1: Mapowanie krajobrazu cenowego](#3-etap-1-mapowanie-krajobrazu-cenowego)
4. [Etap 2: Klasyfikacja epizodów cenowych yearly](#4-etap-2-klasyfikacja-epizodów-cenowych-yearly)
5. [Etap 3: Sygnatura strategii cenowej KDS](#5-etap-3-sygnatura-strategii-cenowej-kds)
6. [Etap 4: Akwizycja klientów w okresach promocji](#6-etap-4-akwizycja-klientów-w-okresach-promocji)
7. [Etap 5: Retencja kohortowa](#7-etap-5-retencja-kohortowa)
8. [Etap 6: Wpływ podwyżek na retencję](#8-etap-6-wpływ-podwyżek-na-retencję)
9. [Wnioski końcowe](#9-wnioski-końcowe)
10. [Definicje operacyjne](#10-definicje-operacyjne)
11. [Kod SQL — pełne kwerendy](#11-kod-sql--pełne-kwerendy)

---

## 1. PYTANIE BADAWCZE

> *„Jak promocje, standardowe ceny i podwyżki wpływają na retencję klientów / nowych klientów? Jest ich mniej? Więcej? Odchodzą szybciej?"*

Pytanie zawiera trzy obiekty (promocje / standardowe ceny / podwyżki) i jedną zmienną zależną (retencja). Ze szczególnym uwzględnieniem nowych klientów.

---

## 2. METODOLOGIA — PRZEGLĄD

Analiza została podzielona na sześć etapów:

1. **Mapowanie krajobrazu cenowego** — identyfikacja "wysp" (epizodów cenowych) metodą gaps-and-islands
2. **Klasyfikacja epizodów yearly** — kategoryzacja wysp na 5 typów biznesowych
3. **Sygnatura strategii cenowej** — analiza wzorców wprowadzania nowych cen
4. **Akwizycja w promocjach** — ile klientów pozyskano w dni promocji yearly
5. **Retencja kohortowa** — porównanie krzywych retencji `new_in_promo` vs `organic`
6. **Wpływ podwyżek** — analiza zachowania klientów w momencie zmian cennika

---

## 3. ETAP 1: MAPOWANIE KRAJOBRAZU CENOWEGO

### 3.1 Założenia segmentacji

Zidentyfikowano trzy segmenty produktowe na podstawie kwoty transakcji:

| Segment | Price threshold | Transactions count | Customers count |
|---|---|---|---|
| `monthly_sub` | < 250 zł | 3 833 | 755 |
| `course_pack` | 250–749 zł | 64 | 34 |
| `yearly` | ≥ 750 zł | 330 | 294 |

**Próg 750 zł** zwalidowany analizą cyklu odnowień klientów: kwoty 756.50, 801, 871.20, 881.10 wykazują wzorzec powrotów co 365–366 dni (subskrypcje roczne).

**Course_pack wyłączony z analizy promocji** — próbka 64 transakcji niereprezentatywna. Pominięcie segmentu
nie wpływa na wnioski.

### 3.2 Definicja wyspy cenowej

Wyspa = ciągły okres aktywnej sprzedaży tej samej ceny. Granica wyspy: luka >7 dni między transakcjami tej samej kwoty.

Metodologia gaps-and-islands z czterema CTE:
1. `gaps` — odstępy między transakcjami tej samej kwoty
2. `island_flags` — flagowanie nowych wysp
3. `islands` — numerowanie wysp w ramach każdej kwoty
4. `island_stats` — agregaty per wyspa (first_seen, last_seen, txn_cnt, span_days, density)

### 3.3 Trzy ery cenowe

Granice er wyznaczone przez zmiany ceny katalogowej yearly:

| Era | Period | Yearly price | Monthly price |
|---|---|---|---|
| **Era 1** | 2023-11-05 do 2024-08-31 | ~990 zł | 99 zł |
| **Era 2** | 2024-09-01 do 2025-09-30 | 1 799 zł | 169 zł |
| **Era 3** | 2025-10-01 do 2026-03-31 | 1 999 zł | 199 zł (249 introduced currently, not present in dataset) |

**Akwizycja per era:**

| Era | monthly_sub | course_pack | yearly | total |
|---|---|---|---|---|
| Era 1 | 138 | 29 | 57 | 224 |
| Era 2 | 401 | 1 | 159 | 561 |
| Era 3 | 212 | 0 | 60 | 272 |

**Era 2 to dominujący okres akwizycyjny** — 53% wszystkich klientów pozyskanych zostało właśnie w tym okresie.

### 3.4 Progi identyfikacji kandydatów na promocje

Dla każdej wyspy: czy wykazuje cechy ponadprzeciętnego epizodu sprzedaży?

| Segment | density threshold | txn_cnt threshold | reasoning |
|---|---|---|---|
| `monthly_sub` | ≥ 3.0 | ≥ 5 | P90 rozkładu density — wyklucza normalne cykle rozliczeniowe |
| `yearly` | ≥ 0.8 | ≥ 2 | Min wśród 8 znanych promocji; segment małowolumenowy |
| `course_pack` | — | — | Wyłączony |

---

## 4. ETAP 2: KLASYFIKACJA EPIZODÓW CENOWYCH YEARLY

### 4.1 Kategorie biznesowe

Każda wyspa-kandydat klasyfikowana wg rabatu % w obie strony (60-dniowe okna kontekstowe):

| Category | Criteria | Count | Interpretation |
|---|---|---|---|
| `classic_promo` | rabat 10–45% vs before I after | 13 | Klasyczna kampania promocyjna |
| `fomo` | rabat 10–45% vs after, <10% vs before | 2 | Ostatnia szansa przed podwyżką |
| `grandfathering` | rabat >45% w którąkolwiek stronę | 4 | Zamrożona cena starego klienta |
| `price_hike` | rabat ujemny (cena wyższa niż kotwica) | 4 | Marker zmiany cennika |
| `uncertain` | NULL w before lub after | 2 | Edge case startu/końca danych |

**RAZEM: 25 wysp promocyjnych cen yearly** w okresie 2023-11 do 2026-03.

### 4.2 Pełna lista epizodów yearly

| Category | Date | Price | Discount % | Count | Span |
|---|---|---|---|---|---|
| uncertain | 2023-11-05 | 801 | NULL/19.1 | 2 | 0 |
| uncertain | 2023-11-05 | 756.50 | NULL/23.6 | 4 | 1 |
| price_hike | 2023-11-06 | 890 | -11.1/10.1 | 4 | 4 |
| classic_promo | 2024-01-03 | 890 | 10.1/10.1 | 6 | 4 |
| price_hike | 2024-06-19 | 1 490 | -50.5/-65.4 | 3 | 0 |
| price_hike | 2024-09-01 | 1 799 | -99.7/0.0 | 7 | 7 |
| classic_promo | 2024-09-08 | 1 599 | 11.1/11.1 | 3 | 0 |
| grandfathering | 2024-11-05 | 801 | 55.5/49.9 | 2 | 0 |
| grandfathering | 2024-11-05 | 756.50 | 57.9/52.7 | 2 | 0 |
| **classic_promo** | **2024-11-25** | **999** | **44.5/44.5** | **23** | **8** |
| **classic_promo** | **2025-01-06** | **999** | **37.5/44.5** | **18** | **8** |
| grandfathering | 2025-03-12 | 959.20 | 46.7/46.7 | 2 | 0 |
| classic_promo | 2025-03-12 | 1 139.05 | 36.7/36.7 | 3 | 0 |
| classic_promo | 2025-03-14 | 1 199 | 33.4/19.5 | 8 | 4 |
| classic_promo | 2025-05-25 | 1 099 | 26.2/26.2 | 20 | 14 |
| classic_promo | 2025-05-31 | 1 022.07 | 31.4/31.4 | 2 | 0 |
| **fomo** | **2025-08-19** | **1 490** | **0.0/25.5** | **23** | **20** |
| fomo | 2025-09-08 | 1 415.50 | 5.0/29.2 | 2 | 0 |
| classic_promo | 2025-10-16 | 1 699.15 | 15.0/15.0 | 3 | 0 |
| grandfathering | 2025-11-05 | 801 | 59.9/59.9 | 2 | 0 |
| classic_promo | 2025-11-22 | 1 499 | 25.0/25.0 | 12 | 9 |
| classic_promo | 2026-01-14 | 1 299 | 35.0/37.8 | 13 | 5 |
| classic_promo | 2026-03-19 | 1 329.05 | 33.5/26.1 | 3 | 1 |
| classic_promo | 2026-03-20 | 1 399 | 30.0/22.2 | 10 | 4 |
| price_hike | 2026-03-20 | 2 089.05 | -4.5/-16.1 | 2 | 0 |

### 4.3 Wnioski o strukturze cen yearly

**Maksymalny rabat KDS: 44.5%** (Black Friday 2024, New Year 2025 — oba 999 zł od kotwicy 1 799 zł).

**Wzorzec mnożników rabatowych:** ceny rabatowe są policzalne od cen katalogowych z mnożnikami 0.8 / 0.85 / 0.9. Przykłady:
- 75.65 = 89 × 0.85 (rabat 15% miesięczny)
- 79.20 = 99 × 0.80 (rabat 20%)
- 871.20 = 1089 × 0.80 (rabat 20% roczny)

---

## 5. ETAP 3: SYGNATURA STRATEGII CENOWEJ KDS

### 5.1 Obserwacja kluczowa

Yearly i monthly_sub wykazują **fundamentalnie różne wzorce** wprowadzania nowych cen.

**Yearly — cięty switch:**

| Transition | First new | Last old | Overlapping days |
|---|---|---|---|
| 990 → 1799 | 2024-09-01 | 2024-08-31 (akt. sprz.) | **0** |
| 1799 → 1999 | 2025-10-08 | 2025-09-29 | **1** |

**Monthly — stopniowe wypieranie:**

| Transition | First new | Last old | Overlapping days |
|---|---|---|---|
| 89 → 99 | 2023-11-06 | 2026-03-06 | **36+** |
| 99 → 169 | 2024-09-01 | 2026-03-31 | **180+** |
| 169 → 199 | 2024-09-10 | 2026-03-30 | **194** |
| 199 → 249 | 2025-09-12 | 2026-03-30 | **134** |

### 5.2 Interpretacja

**Yearly** = decyzja punktowa właściciela. Klient kupujący po dacie X płaci nową cenę albo jest grandfathered. Brak strefy szarej.

**Monthly** = stopniowe testowanie rynku. Nowa cena uruchamiana równolegle ze starą. Stara wygasa naturalnie, nie jest odcinana. Klienci mogą nadal kupować po starej cenie przez wiele miesięcy po wprowadzeniu nowych cen rocznych.

### 5.3 Konsekwencje dla analizy

- Sztywne granice er (2024-09-01, 2025-10-01) wyznaczone przez yearly są **dokładne** dla yearly, **umowne** dla monthly_sub.
- Akwizycja nowych klientów monthly nie pokrywa się jeden-do-jeden z erą cenową — klient może zapłacić starą cenę w nowej erze.

---

## 6. ETAP 4: AKWIZYCJA KLIENTÓW W OKRESACH PROMOCJI

### 6.1 Tabela: pozyskanie klientów per wyspa promocyjna yearly

Dla 15 wysp typu `classic_promo` lub `fomo`:

| Beginning date | End date | Days | Price | Discount | Acquired yearly | Yearly revenue | Acquired monthly | Monthly revenue |
|---|---|---|---|---|---|---|---|---|
| 2024-01-03 | 2024-01-07 | 5 | 890 | 10.1% | 6 | 5 340.00 | 9 | 801.00 |
| 2024-09-08 | 2024-09-08 | 1 | 1 599 | 11.1% | 3 | 4 797.00 | 29 | 4 824.95 |
| **2024-11-25** | 2024-12-02 | 8 | 999 | **44.5%** | **22** | **21 978.00** | 13 | 2 291.20 |
| 2025-01-06 | 2025-01-13 | 8 | 999 | 44.5% | 18 | 17 982.00 | 13 | 2 197.00 |
| 2025-03-12 | 2025-03-12 | 1 | 1 139.05 | 36.7% | 3 | 3 417.15 | 3 | 490.10 |
| 2025-03-14 | 2025-03-17 | 4 | 1 199 | 33.4% | 7 | 8 393.00 | 6 | 963.30 |
| 2025-05-25 | 2025-06-08 | 15 | 1 099 | 26.2% | 18 | 19 782.00 | 27 | 4 437.94 |
| 2025-05-31 | 2025-05-31 | 1 | 1 022.07 | 31.4% | 2 | 2 044.14 | 1 | 160.55 |
| **2025-08-19** | **2025-09-08** | **21** | **1 490 (fomo)** | **25.5%** | **22** | **32 780.00** | **48** | **9 273.40** |
| 2025-09-08 | 2025-09-08 | 1 | 1 415.50 | 29.2% | 2 | 2 831.00 | 13 | 2 507.40 |
| 2025-10-16 | 2025-10-16 | 1 | 1 699.15 | 15.0% | 3 | 5 097.45 | 3 | 634.95 |
| 2025-11-22 | 2025-12-01 | 10 | 1 499 | 25.0% | 12 | 17 988.00 | 31 | 6 045.62 |
| 2026-01-14 | 2026-01-19 | 6 | 1 299 | 37.8% | 12 | 15 588.00 | 20 | 3 870.55 |
| 2026-03-19 | 2026-03-20 | 2 | 1 329.05 | 33.5% | 3 | 3 987.15 | 5 | 1 062.15 |
| 2026-03-20 | 2026-03-24 | 5 | 1 399 | 30.0% | 8 | 11 192.00 | 18 | 3 898.20 |

**Podsumowanie 15 wysp:**

| Segment | Acquired | Revenue (zł) |
|---|---|---|
| yearly | 141 | 173 196.89 |
| monthly | 239 | 43 458.31 |
| **RAZEM** | **380** | **216 655.20** |

### 6.2 Wnioski o akwizycji

**Wniosek A1 — efekt halo:** akwizycja monthly w dni promocji yearly jest **3.34x większa** niż w dni nie-promocyjne (2.57 vs 0.77 nowych klientów monthly per dzień). 11% dni (promocyjnych) generuje 29% wszystkich nowych klientów monthly.

**Wniosek A2 — promocje yearly są przede wszystkim narzędziem akwizycyjnym:** 94.6% transakcji na cenę promocyjną pochodzi od nowych klientów (141 z 149 transakcji). Tylko 5.4% to odnowienia.

**Wniosek A3 — wartość kohort:** 80% przychodu z promocji generują klienci yearly (173k vs 43k zł), mimo że stanowią 37% kohorty. LTV pojedynczego klienta yearly w punkcie pozyskania to ~7x LTV monthly.

**Wniosek A4 — korelacja rabat % vs akwizycja:** Pearson 0.392 (umiarkowana). Większe rabaty przyciągają więcej klientów łącznie, ale efekt jest głównie wynikiem dłuższego trwania promocji (avg 6.83 dnia dla rabatów ≥25% vs 2.33 dla <25%), nie wyższej intensywności per dzień.

**Wniosek A5 — najmocniejsze halo per dzień to jednodniowe promocje:** 1599 zł (29 monthly w 1 dzień), 1415.50 zł (13 monthly w 1 dzień). Skoncentrowana komunikacja marketingowa.

---

## 7. ETAP 5: RETENCJA KOHORTOWA

### 7.1 Definicje kohort

- **`new_in_promo_day`** — klient, którego pierwsza transakcja nastąpiła w oknie wyspy promocyjnej yearly (dla yearly: także po cenie wyspy)
- **`organic`** — wszyscy pozostali

### 7.2 Retencja monthly_sub

**Rozmiar kohort:**
- new_in_promo_day: 221
- organic: 530

**Statystyki życia:**

| Cohort | Avg txn | Median txn | Avg lifespan (days) | Median lifespan | Avg revenue |
|---|---|---|---|---|---|
| new_in_promo_day | 4.62 | 3 | 114 | 62 | 825 zł |
| organic | 5.31 | 3 | 145 | 61 | 833 zł |

**Krzywa retencji (okno ±15 dni od dnia N-tego miesiąca):**

| Horizon | new_in_promo_day | organic | Difference (p.p.) |
|---|---|---|---|
| 1M | **79.7%** | 71.9% | **+7.8** |
| 3M | **58.8%** | 45.9% | **+12.9** |
| 6M | **37.2%** | 32.0% | **+5.2** |
| 12M | 20.5% | **23.4%** | -2.9 |

### 7.3 Retencja yearly

**Rozmiar kohort:**
- new_in_promo_day: 141
- organic: 135

**Statystyki życia:**

| Cohort | Avg txn | Median txn | Avg lifespan | Median lifespan | Avg revenue |
|---|---|---|---|---|---|
| new_in_promo_day | 1.06 | 1 | 19 dni | 0 dni | 1 286 zł |
| organic | 1.29 | 1 | 85 dni | 0 dni | 1 533 zł |

**Mediana lifespan = 0 dni dla obu kohort** — połowa klientów yearly nigdy nie wraca.

**Krzywa retencji (okno ±30 dni; 6M nieinformatywne — yearly ma cykl 12M):**

| Horizon | new_in_promo_day | organic | Difference (p.p.) |
|---|---|---|---|
| 12M | 11.9% | **25.3%** | **-13.4** |
| 18M | 0.0% | 3.2% | -3.2 |
| 24M | 0.0% | **29.2%** | -29.2 |

**Retencja skumulowana (jakakolwiek transakcja po N dniach):**

| Horizon | new_in_promo_day | organic | Difference (p.p.) |
|---|---|---|---|
| 12M | 3.4% | **24.1%** | **-20.7** |
| 18M | 0.0% | 12.7% | -12.7 |
| 24M | 0.0% | 25.0% | -25.0 |

### 7.4 Wnioski o retencji

**Wniosek R1 — segment monthly:** klienci pozyskani w dniach promocji yearly mają **wyższą retencję krótko- i średnioterminową** (do 6 miesięcy) niż klienci organic. Po 12 miesiącach efekt się odwraca, ale różnica jest niewielka (2.9 p.p.).

**Wniosek R2 — segment yearly:** klienci pozyskani w promocji mają **dramatycznie niższą retencję 12-miesięczną** (11.9% vs 25.3%) i praktycznie żadnej długoterminowej (0% vs 25-29% organic w 18-24M).

**Wniosek R3 — efekt łowców okazji występuje w segmencie yearly, nie monthly.** Dla yearly hipoteza "promocje przyciągają klientów o niższym LTV" potwierdza się. W przypadku monthly jest fałszywa.

**Wniosek R4 — średni przychód per klient yearly:**
- new_in_promo_day: 1 286 zł
- organic: 1 533 zł
- Różnica 247 zł = ~16% niższe LTV klienta promocyjnego

---

## 8. ETAP 6: WPŁYW PODWYŻEK NA RETENCJĘ

### 8.1 Podwyżka 2025-10-01 (Era 2 → Era 3)

Mianownik: 166 klientów Ery 2 monthly_sub aktywnych w momencie podwyżki (ostatnia transakcja w oknie 2025-08-27 do 2025-09-30).

| Status | Liczba | % |
|---|---|---|
| **UPGRADE** (przeszli na 199/249) | 88 | **53.0%** |
| **GRANDFATHERED** (kontynuowali 169) | 30 | **18.1%** |
| **CHURN** (nie pojawili się w E3) | 26 | **15.7%** |
| **INNE** (rabat, zmiana planu) | 22 | 13.3% |

**Kluczowa obserwacja:** ze wszystkich 30 klientów grandfathered (płacących 169 zł w Erze 3) **100% grandfathered których status jest weryfikowalny w obecnym oknie — nie odnowiło**. 15 klientów ma jeszcze okazję przejścia na cenę 199 lub rezygnacji. Dla przypadków możliwych do zweryfikowania efekt grandfathering to nie alternatywa — to ostatnia płatność przed odejściem.

### 8.2 Podwyżka 2024-09-01 (Era 1 → Era 2)

Mianownik: 64 klientów Ery 1 monthly_sub aktywnych w momencie podwyżki.

| Status | Liczba | % |
|---|---|---|
| **GRANDFATHERED** (cena z Ery 1) | 55 | **85.9%** |
| **CHURN** (nie pojawili się w E2) | 7 | 10.9% |
| **UPGRADE** (przeszli na 169) | 2 | **3.1%** |

**Wszystkie 55 osób grandfathered z Ery 1 ostatecznie kończy** — ich ostatnia transakcja to grandfathered cena z Ery 1.

### 8.3 Porównanie reakcji na podwyżki

| Kategoria | Era 1 (n=64) | Era 2 (n=166) |
|---|---|---|
| CHURN | 10.9% | 15.7% |
| GRANDFATHERED | **85.9%** | 18.1% |
| UPGRADE | **3.1%** | **53.0%** |

### 8.4 Wnioski o podwyżkach

**Wniosek P1 — radykalnie różne reakcje na dwie podwyżki:**
- Era 1 → 2 (skok cen o 70.7%): tylko 3% klientów akceptuje upgrade, 86% pozostaje na starej cenie
- Era 2 → 3 (skok cen o 17.8%): 53% akceptuje upgrade, 18% grandfathered

**Wniosek P2 — grandfathered = przedłużone odejście, nie kontynuacja:** w obu erach **100% klientów grandfathered ostatecznie odchodzi**. Stara cena to tylko buforowanie w czasie momentu odejścia.

**Wniosek P3 — wielkość podwyżki determinuje odporność klientów (z istotnymi zastrzeżeniami):**

Surowe liczby sugerują, że mniejsza podwyżka (Era 2 → 3, +17.8% ceny) była łatwiejsza do przełknięcia (53% upgrade) niż większa (Era 1 → 2, +70.7% ceny, tylko 3% upgrade). 

**Zastrzeżenia metodologiczne — krytyczne dla interpretacji:**
- **Mianowniki nieporównywalne** (64 vs 166 klientów). Era 1 to wczesny etap KDS, mała baza klientów, inny profil produktu i komunikacji.
- **Asymetryczne okno obserwacji.** Klienci Ery 1 grandfathered mieli **12 miesięcy** do kolejnej podwyżki, dłuższy czas na podjęcie decyzji o odejściu. Klienci Ery 2 grandfathered mają tylko **6 miesięcy** do końca okna danych (right-censored).
- **Wpływ dojrzałości produktu.** Wyższa retencja w Erze 2 może wynikać z dojrzalszego produktu, lepszego marketingu, ugruntowanej bazy lojalnych klientów — nie tylko ze skali samej podwyżki.

**Z tych powodów nie można jednoznacznie powiedzieć, że to wielkość podwyżki jest jedyną przyczyną różnic. Wniosek P3 wskazuje korelację, nie przyczynowość.**

---

## 9. WNIOSKI KOŃCOWE

### 9.1 Odpowiedzi na pytanie konkursowe

**„Jak promocje wpływają na retencję? Odchodzą szybciej?"**

Odpowiedź jest **zależna od segmentu**:

- **Monthly_sub:** klienci pozyskani w dniach promocji yearly NIE odchodzą szybciej w krótkim terminie. W pierwszych 6 miesiącach mają **wyższą retencję** (do +12.9 p.p. po 3M, na próbkach 462–502 obserwacji organic / 182–202 obserwacji promo). Łowcy okazji nieobecni w tym segmencie.

- **Yearly:** klienci pozyskani w promocji mają **niższą retencję 12-miesięczną** (11.9% vs 25.3%) na próbkach kohorty klientów kwalifikujących się ze względu na ograniczenia czasowe datasetu 59 obserwacji promo / 79 obserwacji organic. Po 18-24 miesiącach efekt jest jeszcze silniejszy, ale próbki kohorty stają się bardzo małe (6–63 obserwacji), więc te liczby należy traktować jako **wskazujące kierunek, nie dowód statystyczny**. Hipoteza "łowców okazji" znajduje wstępne potwierdzenie dla yearly i wymaga dodatkowej walidacji na większym oknie obserwacji.

**„Jak podwyżki wpływają na retencję?"**

Podwyżka generuje:
- 16-34% natychmiastowy churn (w zależności od skali podwyżki)
- 18-86% klientów grandfathered, ale ogromna część z nich ostatecznie odchodzi:
  wszyscy klienci Era 1, 15 z 30 klientów Era 2.
- Tylko 3-53% obecnych subskrybujących akceptuje nową cenę i kontynuuje subskrypcję

**„Jak standardowe ceny wpływają na retencję?"**

Klienci `organic` (kupujący po standardowych cenach) mają:
- Niższą retencję krótkoterminową niż promocyjni (monthly)
- Wyższą retencję długoterminową niż promocyjni (oba segmenty)
- Wyższe średnie LTV: 1 533 zł vs 1 286 zł (yearly), porównywalne (monthly)

### 9.2 Kluczowe rekomendacje biznesowe

**Rekomendacja 1:** Promocje yearly należy traktować jako narzędzie **akwizycji wolumenu**, nie wartości. Łowcy okazji generują niższy LTV i nie wracają.

**Rekomendacja 2:** Promocje yearly mają **silny efekt halo na monthly** (3.34x wzrost akwizycji). Wartość promocji yearly należy mierzyć łącznie: bezpośredni przychód yearly + efekt halo monthly.

**Rekomendacja 3:** Strategia "monthly displacement" (stopniowe wypieranie starej ceny) ogranicza churn przy podwyżkach w porównaniu do "yearly switch" — klienci mają czas na adaptację. Zaleca się utrzymanie tej strategii.

**Rekomendacja 4:** Grandfathering nie jest narzędziem retencji — to opóźniony churn. W obecnym oknie danych żaden z klientów grandfathered (przy obu podwyżkach) nie odnowił subskrypcji po swojej ostatniej płatności. Należy rozważyć aktywną komunikację z klientami segmentu grandfathered jako grupą wysokiego ryzyka.

**Rekomendacja 5:** Mniejsze rabaty (<25%) mają wyższą efektywność per dzień, ale mniejszy zasięg. Większe rabaty (≥25%) mają niższą efektywność dzienną, ale dłuższe trwanie i większy efekt halo. Optymalny mix powinien zawierać oba typy.

### 9.3 Ograniczenia analizy

1. **Okno danych** kończy się 2026-03-31. Klienci pozyskani w ostatnich 12 miesiącach nie mogą być oceniani na pełnym horyzoncie 12M.
2. **Retencja długoterminowa yearly** opiera się na małych próbkach (kohorty 18-24M mają 6-63 obserwacji).
3. **Hipoteza półrocznej subskrypcji w Erze 1** — nie zweryfikowana, oznaczona komentarzem.
4. **Kategoria grandfathering w klasyfikacji wysp** łączy dwa zjawiska: (a) starych klientów z Ery 1, (b) klientów z anomalnymi rabatami. Rozróżnienie wymagałoby dodatkowej analizy per-klient.

---

## 10. DEFINICJE OPERACYJNE

### 10.1 Era pozyskania klienta

Era kalendarzowa wyznaczona przez datę pierwszej transakcji klienta:
- **Era 1:** 2023-11-05 do 2024-08-31
- **Era 2:** 2024-09-01 do 2025-09-30
- **Era 3:** 2025-10-01 do 2026-03-31

### 10.2 Pozyskany w promocji

**`new_in_promo`** — pierwsza w historii transakcja klienta:
1. Nastąpiła w oknie czasowym wyspy `classic_promo` lub `fomo`, ORAZ
2. Była zawarta po cenie tej wyspy

**`reactivated_by_promo`** — klient nie jest nowy, ale:
1. Wypadł z okna aktywności (>35 dni monthly / >370 dni yearly), ORAZ
2. Wrócił transakcją spełniającą warunki `new_in_promo`

**`organic`** — wszyscy pozostali (default).

### 10.3 Retencja kohortowa

Klient zretencjonowany po N miesiącach (`retained_after_N_months = TRUE`), jeżeli posiadał aktywny dostęp w miesiącu (X + N), gdzie X = miesiąc pierwszej transakcji.

**Aktywny dostęp:**
- Monthly: transakcja w oknie [(X+N)-15d, (X+N)+15d]
- Yearly: transakcja w oknie [(X+N)-30d, (X+N)+30d]

**Horyzonty:** 1, 3, 6, 12 miesięcy (monthly); 6, 12, 18, 24 miesięcy (yearly).

### 10.4 Próg luki dla wyspy

Luka >7 dni między transakcjami tej samej kwoty rozpoczyna nową wyspę.

### 10.5 Okno kontekstowe rabatu

60 dni przed `first_seen` i 60 dni po `last_seen` wyspy, z wykluczeniem samej wyspy.

---

## 11. KOD SQL — PEŁNE KWERENDY

Pełne kwerendy znajdują się w osobnych plikach:

- `01_vw_promo_classification.sql` — widok klasyfikacji wysp yearly
- `02_vw_fct_clients_v15.sql` — widok klientów z atrybutami pozyskania
- `03_acquisition_per_island.sql` — tabela akwizycji per wyspa promocyjna
- `04_cohort_retention_monthly.sql` — analiza retencji monthly
- `05_cohort_retention_yearly.sql` — analiza retencji yearly
- `06_price_hike_impact.sql` — wpływ podwyżek na retencję
- `07_signature_proof.sql` — dowód SQL "switch vs displacement"

---

**KONIEC DOKUMENTU**

