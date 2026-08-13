# romantic_collation

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fromantic_collation.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

Citește în: [English](README.md) · [Français](README.fr.md) · [Español](README.es.md) ·
[Italiano](README.it.md) · [Português (Brasil)](README.pt_br.md) · [Català](README.ca.md) · **Română**

O bibliotecă mică pentru colarea și sortarea șirurilor, rapidă, cu reguli
proprii, multiplatformă și reproductibilă. Include propria ordine versionată și
nu consultă niciodată configurarea regională a sistemului.

## De ce

`sort`, `rg`, `fd` și unelte similare depind de colarea regională, care se
schimbă cu glibc, lipsește în musl sau cere ICU. romantic_collation compilează o
ordine documentată în binar și produce același rezultat, octet cu octet, pe
glibc, musl, macOS și Windows. `--code-point` oferă ordinea exactă a
`LC_ALL=C sort`.

## Stil propriu

1. `spații < punctuație < cifre < litere`; spațiile și punctuația sunt
   semnificative.
2. Secvențele numerice sunt naturale și de precizie arbitrară:
   `file2 < file10`, `-10 < -5 < 0`. Implicit, `1.9 < 1.10` este ordine de
   versiune; `--decimal` activează zecimale și absoarbe separatorii dintre cifre.
3. Literele de bază nu diferențiază majusculele, iar minusculele vin primele.
4. Majoritatea diacriticelor departajează secundar: `café < cafz`.
5. Pozițiile spaniole și românești sunt primare: `n < ñ < o`, `a < ă < â < b`,
   `i < î < j`, `s < ș < t`, `t < ț < u`. Grafiile românești cu virgulă,
   cedilă și mărci descompuse sunt egale.
6. `ß`→`ss`, `œ`→`oe`, `æ`→`ae`, `ĳ`→`ij`. Ordinea rămâne totală.
7. Configurarea regională a sistemului nu influențează niciodată rezultatul.

## Compilare și testare

```sh
./build          # ReleaseFast prin nix build; instalează zig-out/bin/collate
./test           # teste Zig și integrare CLI
./build --debug  # compilare locală de depanare
```

## CLI

```sh
collate [OPȚIUNI] [FIȘIER]

  -t, --field-separator <SEP>  separă câmpuri
  -k, --key <N>                sortează după al N-lea câmp
  -c, --code-point             ordine UTF-8 brută
  -d, --decimal[=SEP]          numere zecimale
  -s, --sci, --scientific[=SEP] notație științifică
  -n, --num, --numeric[=SEP]   zecimal + științific
      --roman                  numere romane de token întreg
      --version-sort           ordine explicită de versiune
  -h, --help                   ajutor
      --about                  versiune și platformă
      --lang <code>            limba interfeței
```

`FIȘIER` poate fi `-` sau `@stdin`. `-t` stabilește separatorul și `-k` alege
câmpul. Folosește `collate --ajutor` sau `collate --limba ro --help` pentru
ajutorul românesc complet.

## API, măsurători și limite

API-ul C este în [include/romantic_collation.h](include/romantic_collation.h):
`rcol_open`, `rcol_compare_utf8`, `rcol_sort_key_utf8` și `rcol_close`. Nucleul Zig
este pur; CLI-ul C folosește acel API. `./bm` înregistrează măsurători, iar
`./fuzz` verifică invariantele de ordine cu o sămânță reproductibilă.

Textul CJK rămâne în ordine de puncte de cod: colarea lingvistică corectă cere
dicționare de citire. Ordinea latină globală evoluează atent; contracțiile
maghiare și cazul turcesc rămân amânate. Detaliile numerice, măsurătorile și
toate limitele sunt în [README-ul englez](README.md) și
[docs/NUMERIC.md](docs/NUMERIC.md).

## Licență

MIT — vezi [LICENSE](LICENSE).
