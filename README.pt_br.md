# romantic_collation

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fromantic_collation.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

Leia em: [English](README.md) · [Français](README.fr.md) · [Español](README.es.md) ·
[Italiano](README.it.md) · **Português (Brasil)** · [Català](README.ca.md) · [Română](README.ro.md)

Uma pequena biblioteca de colação e ordenação de cadeias, rápida, com critério
próprio, multiplataforma e reproduzível. Inclui a sua própria ordem versionada e
nunca consulta a configuração regional do sistema.

## Por que

`sort`, `rg`, `fd` e ferramentas semelhantes dependem de uma colação regional
que muda com glibc, falta em musl ou exige ICU. romantic_collation compila uma
ordem documentada no binário e produz o mesmo resultado, byte por byte, em
glibc, musl, macOS e Windows. `--code-point` dá a ordem exata de `LC_ALL=C sort`.

## Estilo próprio

1. `espaços < pontuação < algarismos < letras`; espaços e pontuação são
   significativos.
2. As sequências numéricas são naturais e de precisão arbitrária:
   `file2 < file10`, `-10 < -5 < 0`. Por padrão, `1.9 < 1.10` é ordem de
   versões; `--decimal` ativa decimais e absorve separadores entre algarismos.
3. As letras base não distinguem maiúsculas e as minúsculas vêm primeiro.
4. A maioria dos diacríticos desempata secundariamente: `café < cafz`.
5. As posições espanholas e romenas são primárias: `n < ñ < o`, `a < ă < â < b`,
   `i < î < j`, `s < ș < t`, `t < ț < u`. As grafias romenas com vírgula,
   cedilha e marcas decompostas são iguais.
6. `ß`→`ss`, `œ`→`oe`, `æ`→`ae`, `ĳ`→`ij`. A ordem continua total.
7. A configuração regional do sistema nunca influencia o resultado.

## Compilar e testar

```sh
./build          # ReleaseFast com nix build; instala zig-out/bin/collate
./test           # testes Zig e integração da CLI
./build --debug  # compilação local de depuração
```

## CLI

```sh
collate [OPÇÕES] [ARQUIVO]

  -t, --field-separator <SEP>  separa campos
  -k, --key <N>                ordena pelo N.º campo
  -c, --code-point             ordem UTF-8 bruta
  -d, --decimal[=SEP]          números decimais
  -s, --sci, --scientific[=SEP] notação científica
  -n, --num, --numeric[=SEP]   decimal + científica
      --roman                  numerais romanos de token inteiro
      --version-sort           ordem de versões explícita
  -h, --help                   ajuda
      --about                  versão e plataforma
      --lang <code>            idioma da interface
```

`ARQUIVO` pode ser `-` ou `@stdin`. `-t` define o separador e `-k` escolhe o
campo. Use `collate --ajuda` ou `collate --linguagem pt_br --help` para a ajuda
completa em português.

## API, medições e limites

A API C está em [include/romantic_collation.h](include/romantic_collation.h):
`rcol_open`, `rcol_strcoll8`, `rcol_get_sort_key` e `rcol_close`. O núcleo Zig
é puro; a CLI C usa essa API. `./bm` registra medições e `./fuzz` verifica os
invariantes de ordem com uma semente reproduzível.

Texto CJK continua em ordem de pontos de código: a ordenação linguística correta
exige dicionários de leitura. A ordem latina global evolui com cuidado; as
contrações húngaras e o caso turco permanecem adiados. Os detalhes numéricos,
as medições e todos os limites estão no [README inglês](README.md) e em
[docs/NUMERIC.md](docs/NUMERIC.md).

## Licença

MIT — veja [LICENSE](LICENSE).
