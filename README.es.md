# romantic_collation

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fromantic_collation.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

Leer en: [English](README.md) · [Français](README.fr.md) · **Español** ·
[Italiano](README.it.md) · [Português (Brasil)](README.pt_br.md) · [Català](README.ca.md) ·
[Română](README.ro.md)

Una biblioteca pequeña de intercalación y ordenación de cadenas, rápida, con
criterio propio, multiplataforma y reproducible. Incluye su orden versionado y
nunca consulta la configuración regional del sistema.

## Por qué

`sort`, `rg`, `fd` y herramientas afines dependen de una ordenación regional que
cambia con glibc, falta en musl o necesita ICU. romantic_collation compila un
orden documentado en el binario y produce el mismo resultado, byte por byte, en
glibc, musl, macOS y Windows. `--code-point` ofrece el orden exacto de
`LC_ALL=C sort`.

## Estilo propio

1. `espacios < puntuación < dígitos < letras`; los espacios y la puntuación son
   significativos.
2. Las secuencias numéricas son naturales y de precisión arbitraria:
   `file2 < file10`, `-10 < -5 < 0`. De forma predeterminada `1.9 < 1.10` es
   orden de versiones; `--decimal` activa decimales y absorbe separadores entre
   dígitos.
3. Las letras base no distinguen mayúsculas y las minúsculas van antes.
4. La mayoría de los diacríticos desempatan secundariamente: `café < cafz`.
5. Las posiciones españolas y rumanas son primarias: `n < ñ < o`,
   `a < ă < â < b`, `i < î < j`, `s < ș < t`, `t < ț < u`. Las grafías rumanas
   con coma, cedilla y marcas descompuestas son iguales.
6. `ß`→`ss`, `œ`→`oe`, `æ`→`ae`, `ĳ`→`ij`. El orden sigue siendo total.
7. La configuración regional del sistema no influye nunca.

## Compilar y probar

```sh
./build          # ReleaseFast mediante nix build; instala zig-out/bin/collate
./test           # pruebas Zig e integración de CLI
./build --debug  # compilación local de depuración
```

## CLI

```sh
collate [OPCIONES] [ARCHIVO]

  -t, --field-separator <SEP>  separa campos
  -k, --key <N>                ordena por el N.º campo
  -c, --code-point             orden UTF-8 sin tratar
  -d, --decimal[=SEP]          números decimales
  -s, --sci, --scientific[=SEP] notación científica
  -n, --num, --numeric[=SEP]   decimal + científica
      --roman                  números romanos de token completo
      --version-sort           orden de versiones explícito
  -h, --help                   ayuda
      --about                  versión y plataforma
      --lang <code>            idioma de la interfaz
```

`ARCHIVO` puede ser `-` o `@stdin`. `-t` establece el separador y `-k` elige el
campo. Use `collate --ayuda` o `collate --idioma es --help` para la ayuda
española completa.

## API, mediciones y límites

La API C está en [include/romantic_collation.h](include/romantic_collation.h):
`rcol_open`, `rcol_compare_utf8`, `rcol_sort_key_utf8` y `rcol_close`. El núcleo Zig
es puro; la CLI C usa esa API. `./bm` registra mediciones y `./fuzz` comprueba
invariantes de orden con una semilla reproducible.

El texto CJK permanece en orden de puntos de código: una ordenación lingüística
correcta necesita diccionarios de lectura. El orden latino global puede cambiar
con cuidado; las contracciones húngaras y el caso turco siguen aplazados. Los
detalles numéricos, mediciones y límites completos están en el
[README inglés](README.md) y [docs/NUMERIC.md](docs/NUMERIC.md).

## Licencia

MIT — vea [LICENSE](LICENSE).
