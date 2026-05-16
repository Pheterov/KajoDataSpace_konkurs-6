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

<img width="680" height="624" alt="image" src="https://github.com/user-attachments/assets/d0d9feba-a47d-4ce3-9071-ecdb91c29cd9" />

Analiza została podzielona na pięć etapów:

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

<img width="1069" height="536" alt="image" src="https://github.com/user-attachments/assets/d6c7da35-cdc8-4140-93aa-349ac1e2c2da" />
**Pionowe przerywane linie** - wskazują granice Er cenowych


---
## 4. ETAP 2: SYGNATURA STRATEGII CENOWEJ KDS

### 4.1 Obserwacja kluczowa

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

### 4.2 Interpretacja

**Monthly** = stopniowe testowanie rynku. Nowa cena uruchamiana równolegle ze starą. Stara wygasa naturalnie, nie jest odcinana. Klienci mogą nadal kupować po starej cenie przez wiele miesięcy po dniu zmiany ceny yearly (dzien zmiany Ery cenowej).

### 4.3 Konsekwencje dla analizy

- Sztywne granice er (2024-09-08, 2025-09-08) wyznaczone przez yearly są **dokładne** dla yearly, **umowne** dla monthly_sub.
- Akwizycja nowych klientów monthly nie pokrywa się jeden-do-jeden z erą cenową — klient może nadal płacić 'starą' cenę w nowej erze.

---

## 5. ETAP 3: AKWIZYCJA KLIENTÓW W OKRESACH PROMOCJI

<img width="882" height="623" alt="image" src="https://github.com/user-attachments/assets/ac35c3e4-8bcb-452c-bfda-69c2fee16228" />

---

## 6. ETAP 4: RETENCJA KOHORTOWA

NOWI klienci pozyskani w DNIU PROMOCJI
<img width="825" height="593" alt="image" src="https://github.com/user-attachments/assets/4b99fcd8-735c-4b6a-90b5-96d2e51c2218" />

NOWI klienci pozyskani POZA DNIAMI PROMOCYJNYMI
<img width="825" height="594" alt="image" src="https://github.com/user-attachments/assets/de2bec28-cd29-490d-9c94-6f2c7ca29477" />

### 7 Definicje kohort

- **`new_in_promo_day`** — klient, którego pierwsza transakcja nastąpiła w dniu promocjii.
  Obsługiwane przypadki:
- klient z segmentu organic, który przerwał subskrypcję i odnowił ją w dniu promocji
- klient z segmentu organic, który zmienił plan z monthly na yearly w dniu promocji
- **`organic`** — klient, którego pierwsza transakcja nastąpiła w dniu innym niż poromocyjnym

### 7.1 Retencja monthly_sub

**Rozmiar kohort:**
- new_in_promo_day: 374
- organic: 544

### 8 Wnioski o podwyżkach

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
