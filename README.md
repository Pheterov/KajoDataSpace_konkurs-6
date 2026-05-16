# Analiza retencji klientów KajoDataSpace
## Wpływ promocji, standardowych cen i podwyżek na zachowanie klientów

**Autor:** Piotr Rzepka  
**Stack:** MySQL 8+ (kwerendy), DuckDB (walidacja)  
**Zakres danych:** 2023-11-05 do 2026-03-31, 4 227 transakcji, 1 057 unikalnych klientów  
**Wersja dokumentu:** 03.05.2026

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
10. [Definicje](#10-definicje)
11. [Kod SQL — pełne kwerendy](#11-kod-sql--pełne-kwerendy)

---

## 1. PYTANIE BADAWCZE

> *„Jak promocje, standardowe ceny i podwyżki wpływają na retencję klientów / nowych klientów? Jest ich mniej? Więcej? Odchodzą szybciej?"*

Pytanie zawiera trzy obiekty (promocje / standardowe ceny / podwyżki) i jedną zmienną zależną (retencja).

---

## 2. METODOLOGIA — PRZEGLĄD

Analiza została podzielona na sześć etapów:

1. **Mapowanie krajobrazu cenowego** — identyfikacja promocji na podstawie wzorców cenowych
2. **Sygnatura strategii cenowej** — analiza wzorców wprowadzania nowych cen
3. **Akwizycja w promocjach** — ilu nowych klientów pozyskano w dni promocji
4. **Retencja kohortowa** — porównanie krzywych retencji `new_in_promo` vs `organic`
5. **Wpływ podwyżek** — analiza zachowania klientów w momencie zmian cennika

---

## 3. ETAP 1: MAPOWANIE KRAJOBRAZU CENOWEGO

### 3.1 Założenia segmentacji

Segmenty produktowe zidentyfikowano na podstawie kwoty transakcji:

| Segment | Próg | Liczba transakcji | Liczba klientów |
|---|---|---|---|
| `monthly_sub` | < 250 zł | 3 833 | 755 |
| `course_pack` | 250–689 zł | 64 | 30 |
| `yearly` | ≥ 690 zł | 330 | 298 |

**Próg 690 zł** zwalidowany analizą cyklu odnowień klientów: ceny powyżej progu wykazują wzorzec powrotów co 365–366 dni (subskrypcje roczne).

**Course_pack wyłączony z analizy promocji** — próbka 30 klientów niereprezentatywna.

### 3.2 Definicja promocji

Cena promocyjna jest mniejsza od ceny katalogowej o % z przedziału 10 - 50

**Wzorzec mnożników rabatowych:** ceny rabatowe są policzalne od cen katalogowych z mnożnikami 0.8 / 0.85 / 0.9. Przykłady:
- 75.65 = 89 × 0.85 (rabat 15% miesięczny)
- 79.20 = 99 × 0.80 (rabat 20%)
- 871.20 = 1089 × 0.80 (rabat 20% roczny)
- 
Dzień promocyjny jest dniem w którym dokonano przynajmniej jednego zakupu po cenie promocyjnej

KajoData Space nie stosuje kuponów promocyjnych do wykorzystania w przyszłości, natomiast ze względu na liczne współprace
oferuje kilkudniowe zniżki dla społeczności innych twórców

### 3.3 Trzy ery cenowe

Granice er wyznaczone przez zmiany ceny katalogowej yearly:

| Era | Okres | Cena katalogowa yearly | Cena katalogowa monthly |
|---|---|---|---|
| **Era 1** | 2023-11-05 do 2024-08-31 | ≥690 zł | 99 zł |
| **Era 2** | 2024-09-01 do 2025-09-30 | 1 799 zł | 169 zł |
| **Era 3** | 2025-10-01 do 2026-03-31 | 1 999 zł | 199 zł |

<img width="992" height="563" alt="image" src="https://github.com/user-attachments/assets/bb74d54f-644e-4bbe-8d5b-934677bc48a3" />

**Era 2 to dominujący okres akwizycyjny** — 53% wszystkich pozyskanych klientów - była też jednocześnie NAJDŁUŻEJ TRWAJĄCĄ ERĄ cenową.

---
## 5. ETAP 3: SYGNATURA STRATEGII CENOWEJ KDS

### 5.1 Obserwacja kluczowa

Yearly i monthly_sub wykazują **fundamentalnie różne wzorce** wprowadzania nowych cen.

**Yearly — cięty switch:**

| Tranzycja | First new | Last old | Dni nakładania |
|---|---|---|---|
| 990 → 1799 | 2024-09-01 | 2024-08-31 | **0** |
| 1799 → 1999 | 2025-10-08 | 2025-09-29 | **1** |

**Monthly — stopniowe wypieranie:**

| Tranzycja | First new | Last old | Dni nakładania |
|---|---|---|---|
| 89 → 99 | 2023-11-06 | 2026-03-06 | **36+** |
| 99 → 169 | 2024-09-01 | 2026-03-31 | **180+** |
| 169 → 199 | 2024-09-10 | 2026-03-30 | **194** |
| 199 → 249 | 2025-09-12 | 2026-03-30 | **134** |

### 5.2 Interpretacja

**Monthly** = stopniowe testowanie rynku. Nowa cena uruchamiana równolegle ze starą. Stara wygasa naturalnie, nie jest odcinana. Klienci mogą nadal kupować po starej cenie przez wiele miesięcy po dniu zmiany ceny yearly (dzien zmiany Ery cenowej).

### 5.3 Konsekwencje dla analizy

- Sztywne granice er (2024-09-08, 2025-09-08) wyznaczone przez yearly są **dokładne** dla yearly, **umowne** dla monthly_sub.
- Akwizycja nowych klientów monthly nie pokrywa się jeden-do-jeden z erą cenową — klient może nadal płacić 'starą' cenę w nowej erze.

---

## 6. ETAP 4: AKWIZYCJA KLIENTÓW W OKRESACH PROMOCJI

<img width="882" height="623" alt="image" src="https://github.com/user-attachments/assets/ac35c3e4-8bcb-452c-bfda-69c2fee16228" />

---

## 7. ETAP 5: RETENCJA KOHORTOWA

NOWI klienci pozyskani w PROMOCJI
<img width="825" height="593" alt="image" src="https://github.com/user-attachments/assets/4b99fcd8-735c-4b6a-90b5-96d2e51c2218" />

NOWI klienci pozyskani POZA DNIAMI PROMOCYJNYMI
<img width="825" height="594" alt="image" src="https://github.com/user-attachments/assets/de2bec28-cd29-490d-9c94-6f2c7ca29477" />

### 7.1 Definicje kohort

- **`new_in_promo_day`** — klient, którego pierwsza transakcja nastąpiła w dniu promocjii.
  Obsługiwane przypadki:
- klient z segmentu organic, który przerwał subskrypcję i odnowił ją w dniu promocji
- klient z segmentu organic, który zmienił plan z monthly na yearly w dniu promocji
- **`organic`** — klient, którego pierwsza transakcja nastąpiła w dniu innym niż poromocyjnym

### 7.2 Retencja monthly_sub

**Rozmiar kohort:**
- new_in_promo_day: 221
- organic: 530

**Statystyki życia:**

| Kohorta | Avg txn | Median txn | Avg lifespan (dni) | Median lifespan | Avg revenue |
|---|---|---|---|---|---|
| new_in_promo_day | 4.62 | 3 | 114 | 62 | 825 zł |
| organic | 5.31 | 3 | 145 | 61 | 833 zł |

**Krzywa retencji (okno ±15 dni od dnia N-tego miesiąca):**

| Horyzont | new_in_promo_day | organic | Różnica (p.p.) |
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

| Kohorta | Avg txn | Median txn | Avg lifespan | Median lifespan | Avg revenue |
|---|---|---|---|---|---|
| new_in_promo_day | 1.06 | 1 | 19 dni | 0 dni | 1 286 zł |
| organic | 1.29 | 1 | 85 dni | 0 dni | 1 533 zł |

**Mediana lifespan = 0 dni dla obu kohort** — połowa klientów yearly nigdy nie wraca.

**Krzywa retencji (okno ±30 dni):**

| Horyzont | new_in_promo_day | organic | Różnica (p.p.) |
|---|---|---|---|
| 12M | 11.9% | **25.3%** | **-13.4** |
| 24M | 0.0% | **29.2%** | -29.2 |

**Retencja skumulowana (jakakolwiek transakcja po N dniach):**

| Horyzont | new_in_promo_day | organic | Różnica (p.p.) |
|---|---|---|---|
| 12M | 3.4% | **24.1%** | **-20.7** |
| 24M | 0.0% | 25.0% | -25.0 |

### 7.4 Wnioski o retencji

**Wniosek R1 — segment monthly:** klienci pozyskani w dniach promocji yearly mają **wyższą retencję krótko i średnioterminową** (do 6 miesięcy) niż klienci organic. Po 12 miesiącach efekt się odwraca, ale różnica jest niewielka (2.9 p.p.).

**Wniosek R2 — segment yearly:** klienci pozyskani w promocji mają **dramatycznie niższą retencję 12-miesięczną** (11.9% vs 25.3%) i praktycznie żadnej długoterminowej (0% vs 25-29% organic w 18-24M).

**Wniosek R3 — efekt łowców okazji występuje w segmencie yearly, nie monthly.** Dla yearly hipoteza "promocje przyciągają klientów o niższym LTV" potwierdza się. Dla monthly jest fałszywa.

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

**W momencie obserwacji 15 z 30 klientów nadal ma szansę na zaakceptowanie nowej ceny, przejście na inny plan lub rezygnację.**
  Jednak historycznie klienci grandfathered nigdy nie decydowali się na upgrade lub zmianę planu, kończyli subskrypcję po cenach poprzedniej ery.

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

**Wniosek P2 — grandfathered = przedłużone odejście, nie kontynuacja:** w obu erach **100% klientów grandfathered możliwych do zweryfikowania ostatecznie odchodzi, nadal mamy 15 klientów których płatnośc została dokonana w marcu 2026**.

**Wniosek P3 — wielkość podwyżki determinuje odporność klientów (z istotnymi zastrzeżeniami):**

Surowe liczby sugerują, że mniejsza podwyżka (Era 2 → 3, +17.8% ceny) była łatwiejsza do przełknięcia (53% upgrade) niż większa (Era 1 → 2, +70.7% ceny, tylko 3% upgrade). 

**Zastrzeżenia metodologiczne — krytyczne dla interpretacji:**
- **Mianowniki nieporównywalne** (64 vs 166 klientów). Era 1 to wczesny etap KDS, mała baza klientów, inny profil produktu i komunikacji.
- **Asymetryczne okno obserwacji.** Klienci Ery 1 grandfathered mieli **12 miesięcy** do kolejnej podwyżki. Klienci grandfathered Ery 2 mają tylko **6 miesięcy** do końca okna danych.
- **Wpływ dojrzałości produktu.** Wyższa retencja w Erze 2 może wynikać z dojrzalszego produktu, lepszej komunikacji marketingowej, ugruntowanej bazy lojalnych klientów — nie tylko ze skali samej podwyżki.

**Z tych powodów nie można jednoznacznie powiedzieć, że to wielkość podwyżki jest jedyną przyczyną różnic. Wniosek P3 wskazuje korelację, nie przyczynowość.**

---

## 9. WNIOSKI KOŃCOWE

### 9.1 Odpowiedź na pytanie konkursowe

**„Jak promocje wpływają na retencję? Odchodzą szybciej?"**

Odpowiedź jest **zależna od segmentu**:

- **Monthly_sub:** klienci pozyskani w dniach promocji yearly NIE odchodzą szybciej w krótkim terminie. W pierwszych 6 miesiącach mają **wyższą retencję** (do +12.9 p.p. po 3M, na próbkach 462–502 obs. organic / 182–202 obs. promo).

- **Yearly:** klienci pozyskani w promocji mają **niższą retencję 12-miesięczną** (11.9% vs 25.3%) na próbkach kohorty eligible 59 obs. promo / 79 obs. organic. Po 24 miesiącach efekt jest jeszcze silniejszy, ale próbki kohorty stają się bardzo małe (6–63 obserwacji), więc te liczby należy traktować jako **wskazujące kierunek, nie dowód statystyczny**. Hipoteza "łowców okazji" znajduje wstępne potwierdzenie dla yearly i wymaga dodatkowej walidacji na większym oknie obserwacji.

**„Jak podwyżki wpływają na retencję?"**

Podwyżka generuje:

Era1 % - Era2 %

- 11%–16% nieodnowień w obecnym oknie obserwacji (Era 1: 10.9%, Era 2: 15.7%)
- 18%–86% klientów wybiera grandfathered, ale 100% z nich ostatecznie odchodzi (15 klientów nadal 'w grze')
- 3%–53% akceptuje nową cenę i kontynuuje subskrypcję
- 13% (tylko Era 2) wybiera inne ścieżki (rabaty, zmiana planu)

**„Jak standardowe ceny wpływają na retencję?"**

Klienci `organic` (kupujący po standardowych cenach) mają:
- Niższą retencję krótkoterminową niż promocyjni (monthly)
- Wyższą retencję długoterminową niż promocyjni (oba segmenty)
- Wyższe średnie LTV: 1 533 zł vs 1 286 zł (yearly), porównywalne (monthly)

### 9.2 Kluczowe rekomendacje biznesowe

**Rekomendacja 1:** Promocje yearly należy traktować jako narzędzie **akwizycji wolumenu**, nie wartości. Łowcy okazji generują niższy LTV i nie odnawiają subskrypcji.

**Rekomendacja 2:** Promocje yearly mają **silny efekt halo na monthly** (3.34x wzrost akwizycji). Wartość promocji yearly należy mierzyć łącznie: bezpośredni przychód yearly + efekt halo monthly.

**Rekomendacja 3:** Strategia "monthly displacement" (stopniowe wypieranie starej ceny) ogranicza churn przy podwyżkach w porównaniu do "yearly switch" — klienci mają czas na adaptację. Zaleca się utrzymanie tej strategii.

**Rekomendacja 4:** Grandfathered nie jest narzędziem retencji — to opóźniony churn. W obecnym oknie danych żaden z klientów grandfathered (przy obu podwyżkach) nie odnowił po swojej ostatniej grandfathered płatności. Należy rozważyć aktywną komunikację z grandfathered jako grupą wysokiego ryzyka.

> **Zastrzeżenie metodologiczne:** wniosek "100% grandfathered odchodzi" opiera się na obserwacji wyłącznie w obecnym oknie danych (do 2026-03-31). Nie wykluczamy, że część klientów grandfathered jeszcze nie weszła w cykl odnowienia (zwłaszcza w przypadku podwyżki Era 2 → 3, gdzie część klientów grandfathered miała ostatnią płatność dopiero w marcu 2026). Pełna walidacja wymaga monitoringu kohorty przez co najmniej 6 miesięcy po końcu okna danych.

**Rekomendacja 5:** Mniejsze rabaty (<25%) mają wyższą efektywność per dzień, ale mniejszy zasięg. Większe rabaty (≥25%) mają niższą efektywność dzienną, ale dłuższe trwanie i większy efekt halo. Optymalny mix powinien zawierać oba typy.

### 9.3 Ograniczenia analizy

1. **Okno danych** kończy się 2026-03-31. Klienci pozyskani w ostatnich 12 miesiącach nie mogą być oceniani na pełnym horyzoncie 12M.
2. **Retencja długoterminowa yearly** opiera się na małych próbkach (kohorty 18-24M mają 6-63 obserwacji).
3. **Hipoteza półrocznej subskrypcji w Erze 1** — nie zweryfikowana, oznaczona komentarzem.
4. **Kategoria `grandfathering` opiera się na progu rabatu 50% vs kontekst.** Klienci z rabatem 46–50% trafiają do `noise` (1 wyspa: 2025-03-12 amount=959.20, 2 nowi klienci). Próg jest empirycznie skalibrowany dla obecnego datasetu — w obecnych danych klienci legacy mają rabat 55–60% (drugi/trzeci rok bez podwyżki), nowi przypadkowi ~46%. Przy znaczącej zmianie cennika może wymagać ponownego strojenia lub przejścia na strukturalne sprawdzanie historii klienta (czy klient miał wcześniejszą transakcję przed wyspą).

---

## 10. DEFINICJE

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

> *W obecnym datasecie kategoria liczy 1 klienta (id=137, yearly: 2024-03-10 → 2025-03-17, delta 372 dni). Z uwagi na pojedynczą obserwację nie analizujemy tej kohorty osobno — w tabelach retencji jest agregowana jako część grupy referencyjnej.*

**`organic`** — wszyscy pozostali (default).

### 10.3 Retencja kohortowa

Klient zretencjonowany po N miesiącach (`retained_after_N_months = TRUE`), jeżeli posiadał aktywny dostęp w miesiącu (X + N), gdzie X = miesiąc pierwszej transakcji.

**Aktywny dostęp:**
- Monthly: transakcja w oknie [(X+N)-15d, (X+N)+15d]
- Yearly: transakcja w oknie [(X+N)-30d, (X+N)+30d]

**Horyzonty:** 1, 3, 6, 12 miesięcy (monthly); 12, 24 miesiące (yearly).

### 10.4 Próg luki dla wyspy

Luka >7 dni między transakcjami tej samej kwoty rozpoczyna nową wyspę.

### 10.5 Okno kontekstowe rabatu

60 dni przed `first_seen` i 60 dni po `last_seen` wyspy, z wykluczeniem samej wyspy.

---

## 11. KOD SQL — PEŁNE KWERENDY

Pełne kwerendy znajdują się w osobnym pliku
