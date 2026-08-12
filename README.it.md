# romantic_collation

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fromantic_collation.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

Leggi in: [English](README.md) · [Français](README.fr.md) · [Español](README.es.md) ·
**Italiano** · [Português (Brasil)](README.pt_br.md) · [Català](README.ca.md) · [Română](README.ro.md)

Una piccola libreria per la collazione e l’ordinamento di stringhe, veloce, con
criterio proprio, multipiattaforma e riproducibile. Include il proprio ordine
versionato e non consulta mai la locale del sistema.

## Perché

`sort`, `rg`, `fd` e strumenti simili dipendono dalla collazione di locale, che
cambia con glibc, manca in musl o richiede ICU. romantic_collation compila un
ordine documentato nel binario e produce lo stesso risultato byte per byte su
glibc, musl, macOS e Windows. `--code-point` offre l’ordine esatto di
`LC_ALL=C sort`.

## Stile proprio

1. `spazi < punteggiatura < cifre < lettere`; spazi e punteggiatura sono
   significativi.
2. Le sequenze numeriche sono naturali e a precisione arbitraria:
   `file2 < file10`, `-10 < -5 < 0`. Per impostazione predefinita `1.9 < 1.10`
   è un ordine di versioni; `--decimal` attiva i decimali e assorbe separatori
   fra cifre.
3. Le lettere base non distinguono maiuscole e le minuscole vengono prima.
4. Quasi tutti i diacritici risolvono secondariamente: `café < cafz`.
5. Le posizioni spagnole e rumene sono primarie: `n < ñ < o`, `a < ă < â < b`,
   `i < î < j`, `s < ș < t`, `t < ț < u`. Le grafie rumene con virgola,
   cediglia e segni decomposti sono uguali.
6. `ß`→`ss`, `œ`→`oe`, `æ`→`ae`, `ĳ`→`ij`. L’ordine resta totale.
7. La locale del sistema non influenza mai il risultato.

## Compilare e testare

```sh
./build          # ReleaseFast con nix build; installa zig-out/bin/collate
./test           # test Zig e integrazione CLI
./build --debug  # compilazione locale di debug
```

## CLI

```sh
collate [OPZIONI] [FILE]

  -t, --field-separator <SEP>  separa i campi
  -k, --key <N>                ordina per l’N-esimo campo
  -c, --code-point             ordine UTF-8 grezzo
  -d, --decimal[=SEP]          numeri decimali
  -s, --sci, --scientific[=SEP] notazione scientifica
  -n, --num, --numeric[=SEP]   decimale + scientifica
      --roman                  numeri romani a token intero
      --version-sort           ordine delle versioni esplicito
  -h, --help                   aiuto
      --about                  versione e piattaforma
      --lang <code>            lingua dell’interfaccia
```

`FILE` può essere `-` o `@stdin`. `-t` imposta il separatore e `-k` sceglie il
campo. Usa `collate --aiuto` oppure `collate --lingua it --help` per l’aiuto
italiano completo.

## API, misure e limiti

L’API C è in [include/romantic_collation.h](include/romantic_collation.h):
`rcol_open`, `rcol_strcoll8`, `rcol_get_sort_key` e `rcol_close`. Il nucleo Zig
è puro; la CLI C usa questa API. `./bm` registra le misure e `./fuzz` verifica
gli invarianti d’ordine con un seme riproducibile.

Il testo CJK resta in ordine di punti di codice: una collazione linguistica
corretta richiede dizionari di lettura. L’ordine latino globale evolve con
cautela; le contrazioni ungheresi e il caso turco restano differiti. I dettagli
numerici, le misure e tutti i limiti sono nel [README inglese](README.md) e in
[docs/NUMERIC.md](docs/NUMERIC.md).

## Licenza

MIT — vedi [LICENSE](LICENSE).
