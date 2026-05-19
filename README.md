# Analiza retencji klientów KajoDataSpace
## Wpływ promocji, standardowych cen i podwyżek na zachowanie klientów

**Autor:** Piotr Rzepka  
**Stack:** MySQL 8+ (kwerendy), DuckDB (walidacja)  
**Zakres danych:** 2023-11-05 do 2026-03-31, 4 227 transakcji, 1 057 unikalnych klientów  
**Wersja dokumentu:** 18.05.2026

---

## SPIS TREŚCI

1. [Pytanie badawcze](#1-pytanie-badawcze)
2. [Metodologia — przegląd](#2-metodologia--przegląd)
3. [Etap 1: Mapowanie krajobrazu cenowego](#3-etap-1-mapowanie-krajobrazu-cenowego)
5. [Etap 2: Retencja kohortowa](#7-etap-5-retencja-kohortowa)

---

## 1. PYTANIE BADAWCZE

> *„Jak promocje, standardowe ceny i podwyżki wpływają na retencję klientów / nowych klientów? Jest ich mniej? Więcej? Odchodzą szybciej?"*

Pytanie zawiera trzy obiekty (promocje / standardowe ceny / podwyżki) i jedną zmienną zależną (retencja).

---

## 2. WSTĘPNA DEKOMPOZYCJA PRZYCHODU

Wykres kołowy nie zawsze jest ulubieńcem analityków, ale jako szybkie otwarcie mojego case study sprawdza się wyjątkowo dobrze.  
Przy zaledwie trzech kategoriach pozostaje czytelny, a dodatkowe informacje umieszczone w środku pączka oraz na wykresie słupkowym poniżej dodają potrzebny kontekst do samych udziałów procentowych, które bez danych absolutnych potrafią prowadzić do mylnych interpretacji.  

&nbsp;  
 
<img width="909" height="665" alt="image" src="https://github.com/user-attachments/assets/95b577f5-844c-4e06-b9ff-220712480f92" />

&nbsp;

Dane są jednoznaczne: subskrypcje miesięczne odpowiadają za 58% przychodu i 71% klientów.  
Zanim jednak uznamy ją za najbardziej wartościowy produkt, warto już teraz zadać sobie pytanie:  
**Czy oparcie strategii o akwizycję klientów z możliwością rezygnacji po pierwszym miesiącu jest bezpieczniejszym i bardziej dochodowym rozwiązaniem niż próba pozyskania klientów rocznych?**  
**Drugą ważną obserwacją może być nieścisłość w ilości miesięcy**.  
Dane obejmują pełne 29 miesięcy aktywności — od pierwszej transakcji w listopadzie 2023 do ostatniej w marcu 2026. Nie są to okrągłe "3 lata", ale właśnie tyle wynosi rzeczywisty czas życia biznesu uchwycony w danych — i tyle liczymy.

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
 
Dzień promocyjny jest dniem w którym dokonano przynajmniej jednego zakupu po cenie promocyjnej

KajoData Space nie stosuje kuponów promocyjnych do wykorzystania w przyszłości, natomiast ze względu na liczne współprace
oferuje kilkudniowe zniżki dla społeczności innych twórców.

### 3.3 Trzy ery cenowe

Granice er wyznaczone przez zmiany ceny katalogowej yearly:  

| Era | Okres | Cena katalogowa yearly | Cena katalogowa monthly |
|---|---|---|---|
| **Era 1** | 2023-11-05 do 2024-09-08 | ≥990 zł | 99 zł |
| **Era 2** | 2024-09-09 do 2025-09-08 | 1 799 zł | 169 zł |
| **Era 3** | 2025-09-09 do 2026-03-31 | 1 999 zł | 199 zł |  

**Pionowe przerywane linie** - wskazują granice Er cenowych  

Wykres pokazuje coś więcej niż wzrost — pokazuje jak biznes subskrypcyjny kumuluje wartość w czasie. Słupki to akwizycja, linie to zasób. W modelu subskrypcyjnym obie miary są równie krytyczne: pozyskanie bez retencji to dziurawy wiadro, retencja bez pozyskania to stagnacja. Tu obie rosną równocześnie — baza aktywnych klientów miesięcznych wzrosła z 61 w listopadzie 2023 do 209 w marcu 2026, bez żadnego trwałego cofnięcia między erami.
Wrzesień jest systematycznie najsilniejszym miesiącem, to nie zbieżność — to weryfikowalny, powtarzalny efekt kampanii FOMO poprzedzającej podwyżkę cen. Mechanizm działa, a jego skuteczność rośnie.
Osobną uwagę wymaga marzec 2026 z rekordem 58 klientów jednorazowych. Liczba ta nie odzwierciedla realnego zachowania — ze względu na right-censoring dataset kończy się przed upływem czasu potrzebnego do odnowienia subskrypcji zakupionej w marcu. Obserwujemy akwizycję, nie decyzję o retencji.
Pytanie biznesowe, na które odpowiada wykres: Czy baza klientów rośnie strukturalnie, czy jedynie rotuje? Dane potwierdzają wzrost strukturalny.  

<img width="1214" height="680" alt="image" src="https://github.com/user-attachments/assets/fc78c111-7531-4b36-bae9-8b06ae2c9efa" />   

Następny krok: Skoro klientów systematycznie przybywa, a wrzesień koncentruje szczytową akwizycję — warto sprawdzić, czy ten wzrost przekłada się proporcjonalnie na przychód i w którym segmencie generowana jest największa wartość.  

<img width="1069" height="536" alt="image" src="https://github.com/user-attachments/assets/d6c7da35-cdc8-4140-93aa-349ac1e2c2da" />  

Porównanie er wymaga wyjaśnienia metodologicznego, bo standardowe year-over-year byłoby tu błędem — ery mają różną długość. Przyjęta metoda zestawia identyczne okna czasowe liczone od daty startu każdej ery. Era 3 trwa od 9 września 2025 do 31 marca 2026 — punkt odniesienia to dokładnie 9 września 2024 – 31 marca 2025 z Ery 2. To jedyna uczciwa metoda porównania.
Wrzesień wyróżnia się strukturalnie: 43 144 zł w 2024 i 77 666 zł w 2025, przy czym subskrypcje roczne stanowiły ponad 55% przychodu w obu przypadkach.  
Pytanie biznesowe, na które odpowiada wykres: Czy podwyżki cen hamują wzrost bazy klientów? Dane temu przeczą — każda era przynosi więcej klientów przy wyższych cenach, a ARPU rośnie z 533 zł w Erze 1 do 794 zł w Erze 2 bez spadku wolumenu.  

Następny krok: Wiemy skąd pochodzi wzrost przychodów i kiedy jest największy. Pozostaje otwarte pytanie o jego trwałość — czy klienci pozyskani w oknie promocyjnym, którzy w dużej mierze napędzają te wyniki, faktycznie zostają na dłużej?  

<img width="979" height="523" alt="image" src="https://github.com/user-attachments/assets/d908653b-dcc7-412f-b633-6e6295d34403" />  

Liczby są jednoznaczne i mocniejsze niż mogłoby się wydawać. Klienci pozyskani w dniu promocji to 53.8% bazy (569 z 1 057), ale generują 72.2% przychodu (752 310 zł z 1 042 515 zł). Każdy promocyjny złoty pracuje 1.3x mocniej niż złoty od klienta organic — pozorny paradoks rozwiązuje się tym, że promocje skutecznie pozyskują klientów do droższego segmentu (yearly), gdzie LTV jest fundamentalnie wyższe.
W yearly mechanizm jest jeszcze ostrzejszy. 84.4% całego przychodu z subskrypcji rocznych (347 tys zł z 411 tys zł) pochodzi od klientów pozyskanych w dniu promocji *co nie jest jednoznaczne z dokonaniem zakupu pakietu rocznego po cenie promocyjnej.* Promocja w KDS nie jest "bramą do tańszego produktu" — jest główną i niemal jedyną ścieżką sprzedaży najdroższego planu. Yearly w dni niezwiązane z promocją sprzedaje się w ilości marginalnej.
Klienci pozyskani we wrześniu 2025 (kampania FOMO) kontynuują płatność aż do marca 2026 — sześć kolejnych miesięcy ciągłej subskrypcji. To dowód że promocje kreują trwałą wartość, nie jednorazowy spike.
Retencja per segment monthly (po wykluczeniu tenure bias): klienci PROMO mają wyższy odsetek lojalnych (74.6% vs 67.0% u organic). Yearly nie pozwala wyciągać rzetelnych wniosków statystycznych z powodu zbyt małej próbki spontanicznej (n=27 po cutoffie 25.03.2025).
Metodologia wykrywania dni promocyjnych opiera się na sygnałach z transakcji yearly: dzień klasyfikowany jako promocyjny, jeśli zawiera transakcję yearly poniżej ceny katalogowej obowiązującej w danej Erze (Era 1: 990 zł, Era 2: 1 799 zł, Era 3: 1 999 zł) — z wykluczeniem płatności grandfathered (klienci płacący starą cenę z poprzedniej Ery, np. 990 zł w Erze 2). Rezultat: 142 dni promocyjnych z 879 dni działalności KDS. Lista uzupełniona o 19 zweryfikowanych i potwierdzonych dat z social mediów, z czego 17 zostało niezależnie wykrytych algorytmicznie — co potwierdza solidność metody.  

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

Wykres prezentuje wyłącznie pozyskania w segmencie miesięcznym (918 klientów w 29 miesiącach) — nowi klienci oraz powroty po przerwie >32 dni. Zgodnie z naszą metodologią klient zaliczony do "promocji" to ten, który zarejestrował pierwszą lub powrotną transakcję w jednym ze 142 zidentyfikowanych dni promocyjnych.
Trzy obserwacje, które zmieniają sposób patrzenia na kampanie:
Wrzesień 2025 (FOMO przed Erą 3): 47 promo vs 19 spontanicznych — odwrócenie zwykłej proporcji. W tym jednym miesiącu kampania wygenerowała 71% akwizycji. Identyczny mechanizm we wrześniu 2024 (39/45).
Listopad 2025 (Black Week): 28 promo vs 27 spontanicznych — perfekcyjny remis. Kampania podwoiła baseline akwizycji listopadowej (~14/m-c) bez kanibalizacji organicznego ruchu.

---

## 6. ETAP 4: RETENCJA KOHORTOWA

NOWI klienci pozyskani w DNIU PROMOCJI - 374 klientów
<img width="930" height="636" alt="image" src="https://github.com/user-attachments/assets/8de1303a-cce0-4610-9ac6-1759e2f1b0c1" />  

Wykres prezentuje wyłącznie klientów pozyskanych w dni promocyjne — śledzi, czy promocja kupuje klienta na chwilę, czy na lata.
Horyzont retencji ograniczamy do 12 miesięcy świadomie. KDS to platforma e-learningowa, a 12 miesięcy w zupełności wystarcza osobie zdecydowanej na przebranżowienie do wyczerpania dostępnego materiału. Dłuższa retencja byłaby anomalią produktową, nie celem biznesowym — klient, który zostaje na drugi rok, opłaca powtórki, nie naukę.
Promocja nie jest jednorazową transakcją — buduje aktywa. Kohorty z maja i września 2024 po 12 miesiącach trzymają retencję odpowiednio połowy i jednej trzeciej startowej bazy.
Lipiec i sierpień 2024 są puste — to jedyne dwa miesiące w historii KDS bez ani jednego pozyskania w promocji. Brak nie wynika ze słabości kanału, tylko z pauzy kampanijnej przed startem Ery 2. Kolejne wakacje (2025) już wyglądają normalnie.
Wrzesień 2025 wygląda tragicznie. Najsilniejsza akwizycja w historii KDS (47 klientów promo, więcej niż wrzesień 2024) — i jednocześnie najszybszy spadek krzywej. Po 6 miesiącach zostało 32%, krzywa pikuje pionowo. Okno 12M zamyka się dopiero we wrześniu 2026, ale sygnał wczesny jest jednoznaczny: ta kohorta nie zachowuje się jak poprzednie. Hipoteza: kampania FOMO 1490 zł kanibalizowała sama siebie — klient, który widział "ostatnia szansa przed podwyżką", kupił monthly jako tańszą alternatywę dla yearly i odszedł, gdy "ostatnia szansa" minęła.

NOWI klienci pozyskani POZA DNIAMI PROMOCYJNYMI - 544 klientów
<img width="904" height="632" alt="image" src="https://github.com/user-attachments/assets/86ebfea1-e816-49ff-b9f7-ad1a5f7bbd56" />

### 7 Definicje kohort

- **`new_in_promo_day`** — klient, którego pierwsza transakcja nastąpiła w dniu promocjii.
  Obsługiwane przypadki:
- klient z segmentu organic, który przerwał subskrypcję i odnowił ją w dniu promocji
- klient z segmentu organic, który zmienił plan z monthly na yearly w dniu promocji
- **`organic`** — klient, którego pierwsza transakcja nastąpiła w dniu innym niż poromocyjnym

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
