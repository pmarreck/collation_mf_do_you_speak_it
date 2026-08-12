# romantic_collation

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fromantic_collation.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

Lire en : [English](README.md) · **Français** · [Español](README.es.md) ·
[Italiano](README.it.md) · [Português (Brasil)](README.pt_br.md) · [Català](README.ca.md) ·
[Română](README.ro.md)

Une petite bibliothèque de collation et de tri de chaînes, rapide, assumée,
multi-plateforme et reproductible. Elle embarque son ordre versionné et ne lit
jamais les paramètres régionaux du système.

## Pourquoi

`sort`, `rg`, `fd` et des outils voisins dépendent d’une collation de locale qui
change selon glibc, manque avec musl, ou exige ICU. romantic_collation compile
un ordre documenté dans le binaire et donne le même résultat, octet pour octet,
sur glibc, musl, macOS et Windows. `--code-point` est l’échappatoire : il donne
l’ordre exact de `LC_ALL=C sort`.

## Style maison

1. `espaces < ponctuation < chiffres < lettres` ; les espaces et la ponctuation
   sont significatifs.
2. Les suites numériques sont naturelles et de précision arbitraire :
   `file2 < file10`, `-10 < -5 < 0`. Par défaut, `1.9 < 1.10` est un ordre de
   versions ; `--decimal` active les décimales et absorbe les séparateurs entre
   chiffres.
3. Les lettres de base sont sans distinction de casse, puis les minuscules
   précèdent les majuscules.
4. La plupart des diacritiques départagent secondairement : `café < cafz`.
5. Les positions espagnoles et roumaines sont primaires : `n < ñ < o`,
   `a < ă < â < b`, `i < î < j`, `s < ș < t`, `t < ț < u`. Les écritures
   roumaines à virgule, à cédille et décomposées sont égales.
6. `ß`→`ss`, `œ`→`oe`, `æ`→`ae`, `ĳ`→`ij`. L’ordre reste total.
7. Aucune locale du système n’influence le résultat.

## Construire et tester

```sh
./build          # ReleaseFast via nix build ; installe zig-out/bin/collate
./test           # tests Zig et intégration CLI
./build --debug  # compilation locale de débogage
```

## CLI

```sh
collate [OPTIONS] [FICHIER]

  -t, --field-separator <SEP>  sépare les champs
  -k, --key <N>                trie selon le Nième champ
  -c, --code-point             ordre UTF-8 brut
  -d, --decimal[=SEP]          nombres décimaux
  -s, --sci, --scientific[=SEP] notation scientifique
  -n, --num, --numeric[=SEP]   décimal + scientifique
      --roman                  nombres romains entiers
      --version-sort           ordre de versions explicite
  -h, --help                   aide
      --about                  version et plateforme
      --lang <code>            langue de l’interface
```

`FICHIER` peut être `-` ou `@stdin`. `-t` définit un séparateur de champ et
`-k` choisit le champ à trier. Consultez `collate --aide` ou `collate --lang fr
--help` pour l’aide française complète.

## API, mesures et limites

L’API C est dans [include/romantic_collation.h](include/romantic_collation.h) :
`rcol_open`, `rcol_strcoll8`, `rcol_get_sort_key` et `rcol_close`. Le cœur Zig
est pur ; la CLI C passe par cette API. `./bm` consigne les mesures et `./fuzz`
vérifie les invariants d’ordre avec une graine reproductible.

Les textes CJK restent en ordre de points de code : il faut des dictionnaires de
lecture pour une collation linguistique correcte. Le style latin global évolue
avec précaution ; les contractions hongroises et le cas turc restent différés.
Les détails numériques, les mesures et toutes les limites sont dans le
[README anglais](README.md) et [docs/NUMERIC.md](docs/NUMERIC.md).

## Licence

MIT — voir [LICENSE](LICENSE).
