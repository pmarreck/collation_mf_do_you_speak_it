# romantic_collation

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fromantic_collation.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

Llegiu en: [English](README.md) · [Français](README.fr.md) · [Español](README.es.md) ·
[Italiano](README.it.md) · [Português (Brasil)](README.pt_br.md) · **Català** · [Română](README.ro.md)

Una biblioteca petita de col·lació i ordenació de cadenes, ràpida, amb criteri
propi, multiplataforma i reproduïble. Inclou el seu ordre versionat i mai no
consulta la configuració regional del sistema.

## Per què

`sort`, `rg`, `fd` i eines semblants depenen d’una col·lació regional que canvia
amb glibc, manca a musl o necessita ICU. romantic_collation compila un ordre
documentat al binari i produeix el mateix resultat, byte per byte, a glibc,
musl, macOS i Windows. `--code-point` dóna l’ordre exacte de `LC_ALL=C sort`.

## Estil propi

1. `espais < puntuació < dígits < lletres`; els espais i la puntuació són
   significatius.
2. Les seqüències numèriques són naturals i de precisió arbitrària:
   `file2 < file10`, `-10 < -5 < 0`. Per defecte, `1.9 < 1.10` és ordre de
   versions; `--decimal` activa decimals i absorbeix separadors entre dígits.
3. Les lletres base no distingeixen majúscules i les minúscules van primer.
4. La majoria de diacrítics desempaten secundàriament: `café < cafz`.
5. Les posicions espanyoles i romaneses són primàries: `n < ñ < o`,
   `a < ă < â < b`, `i < î < j`, `s < ș < t`, `t < ț < u`. Les grafies
   romaneses de coma, cedilla i marques descompostes són iguals.
6. `ß`→`ss`, `œ`→`oe`, `æ`→`ae`, `ĳ`→`ij`. L’ordre continua sent total.
7. La configuració regional del sistema mai no influeix en el resultat.

## Compilar i provar

```sh
./build          # ReleaseFast amb nix build; instal·la zig-out/bin/collate
./test           # proves Zig i integració de la CLI
./build --debug  # compilació local de depuració
```

## CLI

```sh
collate [OPCIONS] [FITXER]

  -t, --field-separator <SEP>  separa camps
  -k, --key <N>                ordena pel N-èsim camp
  -c, --code-point             ordre UTF-8 en brut
  -d, --decimal[=SEP]          nombres decimals
  -s, --sci, --scientific[=SEP] notació científica
  -n, --num, --numeric[=SEP]   decimal + científica
      --roman                  numerals romans de token sencer
      --version-sort           ordre de versions explícit
  -h, --help                   ajuda
      --about                  versió i plataforma
      --lang <code>            llengua de la interfície
```

`FITXER` pot ser `-` o `@stdin`. `-t` defineix el separador i `-k` tria el
camp. Useu `collate --ajut` o `collate --llengua ca --help` per a l’ajuda
catalana completa.

## API, mesures i límits

L’API C és a [include/romantic_collation.h](include/romantic_collation.h):
`rcol_open`, `rcol_compare_utf8`, `rcol_sort_key_utf8` i `rcol_close`. El nucli Zig
és pur; la CLI C utilitza aquesta API. `./bm` registra mesures i `./fuzz`
verifica els invariants d’ordre amb una llavor reproduïble.

El text CJK resta en ordre de punts de codi: la col·lació lingüística correcta
exigeix diccionaris de lectura. L’ordre llatí global evoluciona amb cura; les
contraccions hongareses i el cas turc continuen diferits. Els detalls numèrics,
les mesures i tots els límits són al [README anglès](README.md) i a
[docs/NUMERIC.md](docs/NUMERIC.md).

## Llicència

MIT — vegeu [LICENSE](LICENSE).
