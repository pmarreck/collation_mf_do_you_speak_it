/*
 * collate — CLI front-end for romantic_collation.
 *
 * Reads lines from stdin (or a file), sorts them via the collation FFI, and
 * writes the sorted lines to stdout. The whole point: a fast, opinionated,
 * REPRODUCIBLE sort that ignores the OS locale entirely.
 *
 * Conventions (per Mecha LLC standards):
 *   - UTF-8 everywhere
 *   - `-h`/`--help`, `--about`, `--version` always work
 *   - `-` / `@stdin` accepted where an input file is expected
 *   - Output about output goes to stderr; the sorted lines go to stdout
 *
 * SPDX-License-Identifier: MIT
 */

#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "romantic_collation.h"

#if defined(__aarch64__) || defined(_M_ARM64)
#define RCOL_ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
#define RCOL_ARCH "x86_64"
#else
#define RCOL_ARCH "unknown"
#endif

#if defined(__APPLE__)
#define RCOL_OS "macos"
#elif defined(__linux__)
#define RCOL_OS "linux"
#elif defined(_WIN32)
#define RCOL_OS "windows"
#else
#define RCOL_OS "unknown"
#endif

static void announce_debug_build(void) {
#ifndef NDEBUG
    if (getenv("MUTE_DEBUG_STATUS") == NULL) {
        fputs("\x1b[33mDEBUG BUILD\x1b[0m\n", stderr);
    }
#endif
}

/* ── i18n (PREPARE phase) ──────────────────────────────────────────────────
 * English is canonical and the fallback. The current prepare-phase catalogs
 * exercise localized aliases and env precedence for German plus the supported
 * Romance languages. Strings live in this typed table (never inline at the use
 * site). Full 50-locale coverage and compile-time enforcement are DEFERRED to
 * the enforce phase — see RULES.md and the i18n skill. */
typedef enum {
    LANG_EN = 0,
    LANG_DE,
    LANG_FR,
    LANG_ES,
    LANG_IT,
    LANG_PT_BR,
    LANG_CA,
    LANG_RO,
    LANG_COUNT,
} lang_t;

typedef struct {
    const char *code;        /* ISO code, e.g. "en" */
    const char *help_alias;  /* localized --help; NULL for English */
    const char *lang_alias;  /* localized --lang; NULL for English */
    const char *about_desc;  /* trailing one-line description in --about */
    const char *help_text;   /* full --help body */
} messages_t;

static const messages_t MESSAGES[LANG_COUNT] = {
    [LANG_EN] = {
        "en",
        NULL,
        NULL,
        "locale-free opinionated collation",
        "collate — fast, opinionated, reproducible, locale-free line sort\n"
        "\n"
        "Usage:\n"
        "  collate [OPTIONS] [FILE]\n"
        "\n"
        "Reads lines from FILE (or stdin) and writes them sorted to stdout.\n"
        "FILE may be '-' or '@stdin' to read standard input (the default).\n"
        "\n"
        "Ordering (default = the opinionated house style):\n"
        "  whitespace < punctuation < digits < letters (structural-first)\n"
        "  natural numeric runs (file2 < file10)\n"
        "  case-insensitive base letters (apple ~ Apple), lowercase first\n"
        "  diacritics as a secondary tie-break (café near cafe, not after z)\n"
        "  Spanish/Romanian primary slots: n < ñ < o; a < ă < â < b; i < î < j;\n"
        "    s < ș < t; t < ț < u (Romanian comma-below/cedilla forms equal)\n"
        "\n"
        "Options:\n"
        "  -t, --field-separator <SEP>  Split each line on SEP (default: whole line)\n"
        "  -k, --key <N>                Sort by the 1-based Nth field; ties -> whole line\n"
        "  -c, --code-point             Pure UTF-8 byte order (== LC_ALL=C sort)\n"
        "  -d, --decimal[=SEP]          Declare the input contains DECIMAL numbers.\n"
        "                               SEP is the decimal mark, '.' (default) or\n"
        "                               ','. Digit-group separators (space, NBSP,\n"
        "                               thin space, ' _ and the other of . ,) are\n"
        "                               then absorbed between digits, so\n"
        "                               999,999.00 < 1,000,000.00 and the same\n"
        "                               values order alike in any convention.\n"
        "                               Default: every '.' is a separator, giving\n"
        "                               version order (1.9 < 1.10).\n"
        "  -s, --sci, --scientific[=SEP]  Recognize scientific notation and order\n"
        "                               by value (2e5 < 1e10). Plain numbers are\n"
        "                               normalized as exponent 0 so mixed lists\n"
        "                               work. Does NOT absorb group separators.\n"
        "  -n, --num, --numeric[=SEP]   Both of the above: exponents AND\n"
        "                               digit-group absorption.\n"
        "      --roman                  Order whole-token Roman numerals by value\n"
        "                               (VII < IX). Canonical, uniform-case tokens\n"
        "                               only; note MIX is legitimately 1009.\n"
        "      --version-sort           Explicit form of the default dot handling\n"
        "  -h, --help                   Show this help\n"
        "      --about                  Print one-line version + platform\n"
        "      --version                Print the library version\n"
        "      --lang <code>            UI language (e.g. en, de, fr, es); overrides env\n"
        "\n"
        "Environment:\n"
        "  ROMANTIC_COLLATION_LANG      UI language (overrides LANG/LC_*)\n"
        "  COLLATE_FIELD_SEP            Default field separator (overridden by -t)\n",
    },
    [LANG_DE] = {
        "de",
        "--hilfe",
        "--sprache",
        "gebietsschema-freie, eigensinnige Sortierung",
        "collate — schnelle, eigensinnige, reproduzierbare Zeilensortierung ohne Gebietsschema\n"
        "\n"
        "Verwendung:\n"
        "  collate [OPTIONEN] [DATEI]\n"
        "\n"
        "Liest Zeilen aus DATEI (oder stdin) und schreibt sie sortiert nach stdout.\n"
        "DATEI darf '-' oder '@stdin' sein, um die Standardeingabe zu lesen (Standard).\n"
        "\n"
        "Reihenfolge (Standard = der eigensinnige Hausstil):\n"
        "  Leerraum < Satzzeichen < Ziffern < Buchstaben (struktur-zuerst)\n"
        "  natürliche Zahlenläufe (file2 < file10)\n"
        "  Groß-/Kleinschreibung-unabhängige Grundbuchstaben (apple ~ Apple), klein zuerst\n"
        "  Diakritika als sekundäres Kriterium (café nahe cafe, nicht nach z)\n"
        "  Spanische/rumänische Grundpositionen: n < ñ < o; a < ă < â < b; i < î < j;\n"
        "    s < ș < t; t < ț < u (rumänische Komma-/Cedillaformen sind gleich)\n"
        "\n"
        "Optionen:\n"
        "  -t, --field-separator <SEP>  Zeile an SEP trennen (Standard: ganze Zeile)\n"
        "  -k, --key <N>                Nach dem N-ten Feld sortieren; gleich -> ganze Zeile\n"
        "  -c, --code-point             Reine UTF-8-Byte-Reihenfolge (== LC_ALL=C sort)\n"
        "  -d, --decimal[=TRZ]          Eingabe enthält DEZIMALZAHLEN. TRZ ist das\n"
        "                               Dezimaltrennzeichen, '.' (Standard) oder ','.\n"
        "                               Tausendertrennzeichen (Leerzeichen, NBSP,\n"
        "                               schmales Leerzeichen, ' _ und das jeweils\n"
        "                               andere von . ,) werden dann zwischen Ziffern\n"
        "                               absorbiert. Standard: jedes '.' ist ein\n"
        "                               Trenner (1.9 < 1.10).\n"
        "  -s, --sci, --scientific[=TRZ]  Wissenschaftliche Notation erkennen und\n"
        "                               nach Wert sortieren (2e5 < 1e10). Zahlen\n"
        "                               ohne Exponent gelten als Exponent 0.\n"
        "  -n, --num, --numeric[=TRZ]   Beides: Exponenten UND Tausendertrenner.\n"
        "      --roman                  Römische Zahlen nach Wert sortieren (VII < IX)\n"
        "      --version-sort           Ausdrückliche Form des Standardverhaltens\n"
        "  -h, --help / --hilfe         Diese Hilfe anzeigen\n"
        "      --about                  Version + Plattform in einer Zeile\n"
        "      --version                Bibliotheksversion anzeigen\n"
        "      --lang / --sprache <code>  Anzeigesprache (z. B. en, de); überschreibt Umgebung\n"
        "\n"
        "Umgebung:\n"
        "  ROMANTIC_COLLATION_LANG      Anzeigesprache (überschreibt LANG/LC_*)\n"
        "  COLLATE_FIELD_SEP            Standard-Feldtrenner (durch -t überschrieben)\n",
    },
    [LANG_FR] = {
        "fr",
        "--aide",
        "--langue",
        "collation assumée sans paramètres régionaux",
        "collate — tri de lignes rapide, assumé, reproductible, sans paramètres régionaux\n"
        "\n"
        "Utilisation :\n"
        "  collate [OPTIONS] [FICHIER]\n"
        "\n"
        "Lit les lignes de FICHIER (ou de l’entrée standard) et les écrit triées sur la sortie standard.\n"
        "FICHIER peut être '-' ou '@stdin' pour lire l’entrée standard (par défaut).\n"
        "\n"
        "Ordre (par défaut = style maison assumé) :\n"
        "  espaces < ponctuation < chiffres < lettres (structure d’abord)\n"
        "  suites numériques naturelles (file2 < file10)\n"
        "  lettres de base sans distinction de casse (apple ~ Apple), minuscules d’abord\n"
        "  diacritiques comme critère secondaire (café près de cafe, pas après z)\n"
        "  positions espagnoles/roumaines : n < ñ < o; a < ă < â < b; i < î < j;\n"
        "    s < ș < t; t < ț < u (formes roumaines virgule/cedille égales)\n"
        "\n"
        "Options :\n"
        "  -t, --field-separator <SEP>  Sépare chaque ligne par SEP (par défaut : ligne entière)\n"
        "  -k, --key <N>                Trie selon le Nième champ ; égalité -> ligne entière\n"
        "  -c, --code-point             Ordre pur des octets UTF-8 (== LC_ALL=C sort)\n"
        "  -d, --decimal[=SEP]          Déclare que l’entrée contient des nombres DÉCIMAUX.\n"
        "                               SEP est la marque décimale, '.' (par défaut) ou\n"
        "                               ','. Les séparateurs de groupes (espace, NBSP,\n"
        "                               espace fine, ' _ et l’autre de . ,) sont alors\n"
        "                               absorbés entre chiffres, donc\n"
        "                               999,999.00 < 1,000,000.00 et les mêmes\n"
        "                               valeurs s’ordonnent dans toute convention.\n"
        "                               Par défaut, chaque '.' est un séparateur, donc\n"
        "                               ordre de versions (1.9 < 1.10).\n"
        "  -s, --sci, --scientific[=SEP]  Reconnaît la notation scientifique et trie\n"
        "                               par valeur (2e5 < 1e10). Les nombres simples\n"
        "                               sont normalisés avec l’exposant 0. N’absorbe\n"
        "                               pas les séparateurs de groupes.\n"
        "  -n, --num, --numeric[=SEP]   Les deux ci-dessus : exposants ET\n"
        "                               absorption des séparateurs de groupes.\n"
        "      --roman                  Trie les chiffres romains entiers par valeur\n"
        "                               (VII < IX). Jetons canoniques, de casse uniforme ;\n"
        "                               MIX vaut légitimement 1009.\n"
        "      --version-sort           Forme explicite du traitement des points par défaut\n"
        "  -h, --help / --aide          Affiche cette aide\n"
        "      --about                  Affiche version + plateforme sur une ligne\n"
        "      --version                Affiche la version de la bibliothèque\n"
        "      --lang / --langue <code> Langue d’interface (p. ex. en, fr) ; prévaut sur l’environnement\n"
        "\n"
        "Environnement :\n"
        "  ROMANTIC_COLLATION_LANG      Langue d’interface (prévaut sur LANG/LC_*)\n"
        "  COLLATE_FIELD_SEP            Séparateur de champ par défaut (remplacé par -t)\n",
    },
    [LANG_ES] = {
        "es",
        "--ayuda",
        "--idioma",
        "ordenación sin configuración regional y con criterio propio",
        "collate — ordenación de líneas rápida, con criterio propio, reproducible y sin configuración regional\n"
        "\n"
        "Uso:\n"
        "  collate [OPCIONES] [ARCHIVO]\n"
        "\n"
        "Lee líneas de ARCHIVO (o de la entrada estándar) y las escribe ordenadas en la salida estándar.\n"
        "ARCHIVO puede ser '-' o '@stdin' para leer la entrada estándar (valor predeterminado).\n"
        "\n"
        "Orden (predeterminado = estilo propio):\n"
        "  espacios < puntuación < dígitos < letras (primero la estructura)\n"
        "  secuencias numéricas naturales (file2 < file10)\n"
        "  letras base sin distinguir mayúsculas (apple ~ Apple), minúsculas primero\n"
        "  diacríticos como desempate secundario (café cerca de cafe, no tras z)\n"
        "  posiciones españolas/rumanas: n < ñ < o; a < ă < â < b; i < î < j;\n"
        "    s < ș < t; t < ț < u (las formas rumanas con coma/cedilla son iguales)\n"
        "\n"
        "Opciones:\n"
        "  -t, --field-separator <SEP>  Divide cada línea por SEP (predeterminado: línea completa)\n"
        "  -k, --key <N>                Ordena por el N.º campo; empate -> línea completa\n"
        "  -c, --code-point             Orden puro de bytes UTF-8 (== LC_ALL=C sort)\n"
        "  -d, --decimal[=SEP]          Declara que la entrada contiene números DECIMALES.\n"
        "                               SEP es la marca decimal, '.' (predeterminada) o\n"
        "                               ','. Los separadores de grupos (espacio, NBSP,\n"
        "                               espacio fino, ' _ y el otro de . ,) se\n"
        "                               absorben entre dígitos, por lo que\n"
        "                               999,999.00 < 1,000,000.00 y los mismos\n"
        "                               valores se ordenan igual en toda convención.\n"
        "                               Predeterminado: cada '.' es separador y da\n"
        "                               orden de versión (1.9 < 1.10).\n"
        "  -s, --sci, --scientific[=SEP]  Reconoce notación científica y ordena\n"
        "                               por valor (2e5 < 1e10). Los números sin\n"
        "                               exponente se normalizan a exponente 0. No\n"
        "                               absorbe separadores de grupos.\n"
        "  -n, --num, --numeric[=SEP]   Ambos anteriores: exponentes Y\n"
        "                               absorción de separadores de grupos.\n"
        "      --roman                  Ordena números romanos de token completo por valor\n"
        "                               (VII < IX). Solo tokens canónicos de una caja;\n"
        "                               MIX vale legítimamente 1009.\n"
        "      --version-sort           Forma explícita del tratamiento de puntos predeterminado\n"
        "  -h, --help / --ayuda         Muestra esta ayuda\n"
        "      --about                  Muestra versión + plataforma en una línea\n"
        "      --version                Muestra la versión de la biblioteca\n"
        "      --lang / --idioma <code> Idioma de la interfaz (p. ej. en, es); prevalece sobre el entorno\n"
        "\n"
        "Entorno:\n"
        "  ROMANTIC_COLLATION_LANG      Idioma de la interfaz (prevalece sobre LANG/LC_*)\n"
        "  COLLATE_FIELD_SEP            Separador de campo predeterminado (anulado por -t)\n",
    },
    [LANG_IT] = {
        "it",
        "--aiuto",
        "--lingua",
        "collazione indipendente dalla locale e con criterio proprio",
        "collate — ordinamento di righe rapido, con criterio proprio, riproducibile e indipendente dalla locale\n"
        "\n"
        "Uso:\n"
        "  collate [OPZIONI] [FILE]\n"
        "\n"
        "Legge le righe da FILE (o dallo standard input) e le scrive ordinate sullo standard output.\n"
        "FILE può essere '-' o '@stdin' per leggere lo standard input (predefinito).\n"
        "\n"
        "Ordinamento (predefinito = stile proprio):\n"
        "  spazi < punteggiatura < cifre < lettere (prima la struttura)\n"
        "  sequenze numeriche naturali (file2 < file10)\n"
        "  lettere base senza distinzione di maiuscole (apple ~ Apple), minuscole prima\n"
        "  diacritici come spareggio secondario (café vicino a cafe, non dopo z)\n"
        "  posizioni spagnole/rumene: n < ñ < o; a < ă < â < b; i < î < j;\n"
        "    s < ș < t; t < ț < u (le forme rumene con virgola/cediglia sono uguali)\n"
        "\n"
        "Opzioni:\n"
        "  -t, --field-separator <SEP>  Divide ogni riga con SEP (predefinito: riga intera)\n"
        "  -k, --key <N>                Ordina per l’N-esimo campo; parità -> riga intera\n"
        "  -c, --code-point             Ordine puro dei byte UTF-8 (== LC_ALL=C sort)\n"
        "  -d, --decimal[=SEP]          Dichiara che l’input contiene numeri DECIMALI.\n"
        "                               SEP è il separatore decimale, '.' (predefinito) o\n"
        "                               ','. I separatori di gruppo (spazio, NBSP,\n"
        "                               spazio sottile, ' _ e l’altro tra . ,) vengono\n"
        "                               assorbiti tra cifre, quindi\n"
        "                               999,999.00 < 1,000,000.00 e gli stessi\n"
        "                               valori si ordinano uguali in ogni convenzione.\n"
        "                               Predefinito: ogni '.' è un separatore e dà\n"
        "                               ordine di versione (1.9 < 1.10).\n"
        "  -s, --sci, --scientific[=SEP]  Riconosce la notazione scientifica e ordina\n"
        "                               per valore (2e5 < 1e10). I numeri semplici\n"
        "                               sono normalizzati con esponente 0. Non assorbe\n"
        "                               separatori di gruppo.\n"
        "  -n, --num, --numeric[=SEP]   Entrambi: esponenti E\n"
        "                               assorbimento dei separatori di gruppo.\n"
        "      --roman                  Ordina i numeri romani a token intero per valore\n"
        "                               (VII < IX). Solo token canonici a caso uniforme;\n"
        "                               MIX vale legittimamente 1009.\n"
        "      --version-sort           Forma esplicita della gestione predefinita dei punti\n"
        "  -h, --help / --aiuto         Mostra questo aiuto\n"
        "      --about                  Mostra versione + piattaforma su una riga\n"
        "      --version                Mostra la versione della libreria\n"
        "      --lang / --lingua <code> Lingua dell’interfaccia (es. en, it); prevale sull’ambiente\n"
        "\n"
        "Ambiente:\n"
        "  ROMANTIC_COLLATION_LANG      Lingua dell’interfaccia (prevale su LANG/LC_*)\n"
        "  COLLATE_FIELD_SEP            Separatore di campo predefinito (sostituito da -t)\n",
    },
    [LANG_PT_BR] = {
        "pt_br",
        "--ajuda",
        "--linguagem",
        "ordenação independente da configuração regional e com critério próprio",
        "collate — ordenação de linhas rápida, com critério próprio, reproduzível e independente da configuração regional\n"
        "\n"
        "Uso:\n"
        "  collate [OPÇÕES] [ARQUIVO]\n"
        "\n"
        "Lê linhas de ARQUIVO (ou da entrada padrão) e as escreve ordenadas na saída padrão.\n"
        "ARQUIVO pode ser '-' ou '@stdin' para ler a entrada padrão (padrão).\n"
        "\n"
        "Ordenação (padrão = estilo próprio):\n"
        "  espaços < pontuação < dígitos < letras (estrutura primeiro)\n"
        "  sequências numéricas naturais (file2 < file10)\n"
        "  letras base sem distinção de maiúsculas (apple ~ Apple), minúsculas primeiro\n"
        "  diacríticos como desempate secundário (café perto de cafe, não depois de z)\n"
        "  posições espanholas/romenas: n < ñ < o; a < ă < â < b; i < î < j;\n"
        "    s < ș < t; t < ț < u (as formas romenas com vírgula/cedilha são iguais)\n"
        "\n"
        "Opções:\n"
        "  -t, --field-separator <SEP>  Separa cada linha por SEP (padrão: linha inteira)\n"
        "  -k, --key <N>                Ordena pelo N.º campo; empate -> linha inteira\n"
        "  -c, --code-point             Ordem pura de bytes UTF-8 (== LC_ALL=C sort)\n"
        "  -d, --decimal[=SEP]          Declara que a entrada contém números DECIMAIS.\n"
        "                               SEP é a marca decimal, '.' (padrão) ou\n"
        "                               ','. Separadores de grupos (espaço, NBSP,\n"
        "                               espaço fino, ' _ e o outro de . ,) são\n"
        "                               absorvidos entre dígitos, portanto\n"
        "                               999,999.00 < 1,000,000.00 e os mesmos\n"
        "                               valores ordenam de igual modo em qualquer convenção.\n"
        "                               Padrão: cada '.' é separador, dando\n"
        "                               ordem de versões (1.9 < 1.10).\n"
        "  -s, --sci, --scientific[=SEP]  Reconhece notação científica e ordena\n"
        "                               por valor (2e5 < 1e10). Números simples são\n"
        "                               normalizados com expoente 0. Não absorve\n"
        "                               separadores de grupos.\n"
        "  -n, --num, --numeric[=SEP]   Ambos: expoentes E\n"
        "                               absorção de separadores de grupos.\n"
        "      --roman                  Ordena numerais romanos de token inteiro por valor\n"
        "                               (VII < IX). Apenas tokens canônicos de uma só caixa;\n"
        "                               MIX vale legitimamente 1009.\n"
        "      --version-sort           Forma explícita do tratamento padrão dos pontos\n"
        "  -h, --help / --ajuda         Mostra esta ajuda\n"
        "      --about                  Mostra versão + plataforma numa linha\n"
        "      --version                Mostra a versão da biblioteca\n"
        "      --lang / --linguagem <code> Idioma da interface (ex.: en, pt_br); prevalece sobre o ambiente\n"
        "\n"
        "Ambiente:\n"
        "  ROMANTIC_COLLATION_LANG      Idioma da interface (prevalece sobre LANG/LC_*)\n"
        "  COLLATE_FIELD_SEP            Separador de campo padrão (substituído por -t)\n",
    },
    [LANG_CA] = {
        "ca",
        "--ajut",
        "--llengua",
        "ordenació sense configuració regional i amb criteri propi",
        "collate — ordenació de línies ràpida, amb criteri propi, reproduïble i sense configuració regional\n"
        "\n"
        "Ús:\n"
        "  collate [OPCIONS] [FITXER]\n"
        "\n"
        "Llegeix línies de FITXER (o de l’entrada estàndard) i les escriu ordenades a la sortida estàndard.\n"
        "FITXER pot ser '-' o '@stdin' per llegir l’entrada estàndard (per defecte).\n"
        "\n"
        "Ordre (per defecte = estil propi):\n"
        "  espais < puntuació < dígits < lletres (primer l’estructura)\n"
        "  seqüències numèriques naturals (file2 < file10)\n"
        "  lletres base sense distingir majúscules (apple ~ Apple), minúscules primer\n"
        "  diacrítics com a desempat secundari (café prop de cafe, no després de z)\n"
        "  posicions espanyoles/romaneses: n < ñ < o; a < ă < â < b; i < î < j;\n"
        "    s < ș < t; t < ț < u (les formes romaneses de coma/cedilla són iguals)\n"
        "\n"
        "Opcions:\n"
        "  -t, --field-separator <SEP>  Separa cada línia per SEP (per defecte: línia sencera)\n"
        "  -k, --key <N>                Ordena pel N-èsim camp; empat -> línia sencera\n"
        "  -c, --code-point             Ordre pur de bytes UTF-8 (== LC_ALL=C sort)\n"
        "  -d, --decimal[=SEP]          Declara que l’entrada conté nombres DECIMALS.\n"
        "                               SEP és la marca decimal, '.' (per defecte) o\n"
        "                               ','. Els separadors de grup (espai, NBSP,\n"
        "                               espai fi, ' _ i l’altre de . ,) s’absorbeixen\n"
        "                               entre dígits; així\n"
        "                               999,999.00 < 1,000,000.00 i els mateixos\n"
        "                               valors s’ordenen igual en tota convenció.\n"
        "                               Per defecte, cada '.' és separador i dóna\n"
        "                               ordre de versions (1.9 < 1.10).\n"
        "  -s, --sci, --scientific[=SEP]  Reconeix notació científica i ordena\n"
        "                               per valor (2e5 < 1e10). Els nombres simples\n"
        "                               es normalitzen amb exponent 0. No absorbeix\n"
        "                               separadors de grup.\n"
        "  -n, --num, --numeric[=SEP]   Tots dos: exponents I\n"
        "                               absorció de separadors de grup.\n"
        "      --roman                  Ordena numerals romans de token sencer per valor\n"
        "                               (VII < IX). Només tokens canònics de caixa uniforme;\n"
        "                               MIX val legítimament 1009.\n"
        "      --version-sort           Forma explícita del tractament de punts per defecte\n"
        "  -h, --help / --ajut          Mostra aquesta ajuda\n"
        "      --about                  Mostra versió + plataforma en una línia\n"
        "      --version                Mostra la versió de la biblioteca\n"
        "      --lang / --llengua <code> Llengua de la interfície (p. ex. en, ca); preval sobre l’entorn\n"
        "\n"
        "Entorn:\n"
        "  ROMANTIC_COLLATION_LANG      Llengua de la interfície (preval sobre LANG/LC_*)\n"
        "  COLLATE_FIELD_SEP            Separador de camp per defecte (anul·lat per -t)\n",
    },
    [LANG_RO] = {
        "ro",
        "--ajutor",
        "--limba",
        "sortare fără configurare regională și cu reguli proprii",
        "collate — sortare de linii rapidă, cu reguli proprii, reproductibilă și fără configurare regională\n"
        "\n"
        "Utilizare:\n"
        "  collate [OPȚIUNI] [FIȘIER]\n"
        "\n"
        "Citește linii din FIȘIER (sau de la intrarea standard) și le scrie sortate la ieșirea standard.\n"
        "FIȘIER poate fi '-' sau '@stdin' pentru intrarea standard (implicit).\n"
        "\n"
        "Ordine (implicit = stilul propriu):\n"
        "  spații < punctuație < cifre < litere (mai întâi structura)\n"
        "  secvențe numerice naturale (file2 < file10)\n"
        "  litere de bază fără diferențierea majusculelor (apple ~ Apple), minuscule mai întâi\n"
        "  diacritice ca departajare secundară (café lângă cafe, nu după z)\n"
        "  poziții spaniole/românești: n < ñ < o; a < ă < â < b; i < î < j;\n"
        "    s < ș < t; t < ț < u (formele românești cu virgulă/cedilă sunt egale)\n"
        "\n"
        "Opțiuni:\n"
        "  -t, --field-separator <SEP>  Desparte fiecare linie la SEP (implicit: linia întreagă)\n"
        "  -k, --key <N>                Sortează după al N-lea câmp; egalitate -> linia întreagă\n"
        "  -c, --code-point             Ordine pură de octeți UTF-8 (== LC_ALL=C sort)\n"
        "  -d, --decimal[=SEP]          Declară că intrarea conține numere ZECIMALE.\n"
        "                               SEP este semnul zecimal, '.' (implicit) sau\n"
        "                               ','. Separatorii de grup (spațiu, NBSP,\n"
        "                               spațiu îngust, ' _ și celălalt dintre . ,) sunt\n"
        "                               absorbiți între cifre, astfel\n"
        "                               999,999.00 < 1,000,000.00 și aceleași\n"
        "                               valori se ordonează la fel în orice convenție.\n"
        "                               Implicit, fiecare '.' este separator și dă\n"
        "                               ordine de versiune (1.9 < 1.10).\n"
        "  -s, --sci, --scientific[=SEP]  Recunoaște notația științifică și sortează\n"
        "                               după valoare (2e5 < 1e10). Numerele simple\n"
        "                               sunt normalizate cu exponentul 0. Nu absoarbe\n"
        "                               separatorii de grup.\n"
        "  -n, --num, --numeric[=SEP]   Ambele de mai sus: exponenți ȘI\n"
        "                               absorbția separatorilor de grup.\n"
        "      --roman                  Sortează numere romane formate dintr-un token după valoare\n"
        "                               (VII < IX). Doar tokeni canonici de aceeași literă;\n"
        "                               MIX este legitim 1009.\n"
        "      --version-sort           Forma explicită a tratării implicite a punctelor\n"
        "  -h, --help / --ajutor        Afișează acest ajutor\n"
        "      --about                  Afișează versiunea + platforma pe o linie\n"
        "      --version                Afișează versiunea bibliotecii\n"
        "      --lang / --limba <code>  Limba interfeței (de ex. en, ro); are prioritate față de mediu\n"
        "\n"
        "Mediu:\n"
        "  ROMANTIC_COLLATION_LANG      Limba interfeței (are prioritate față de LANG/LC_*)\n"
        "  COLLATE_FIELD_SEP            Separator de câmp implicit (înlocuit de -t)\n",
    },
};

/* Map a locale code (bare "de" or "pt_BR.UTF-8" etc.) to a supported lang.
 * Normalize '-' and '_' to the canonical underscore form, preserve all language
 * subtags through the encoding/modifier suffix, then match the complete code.
 * This prevents pt_PT from accidentally selecting the pt_br catalog.
 * Returns 1 and sets *out on match; 0 if unsupported. */
static int lang_from_code(const char *code, lang_t *out) {
    if (!code || !code[0]) return 0;
    char buf[16];
    size_t n = 0;
    while (code[n] && n < sizeof(buf) - 1 &&
           code[n] != '.' && code[n] != '@') {
        unsigned char c = (unsigned char)code[n];
        buf[n] = (c == '-' || c == '_') ? '_' : (char)tolower(c);
        n++;
    }
    buf[n] = '\0';
    for (int i = 0; i < LANG_COUNT; i++) {
        if (strcmp(buf, MESSAGES[i].code) == 0) { *out = (lang_t)i; return 1; }
    }
    /* A simple catalog accepts normal regional spellings such as de_DE. Do
     * this only after the full match, so pt_BR reaches pt_br while pt_PT does
     * not silently select it. */
    char *subtag = strchr(buf, '_');
    if (subtag) {
        *subtag = '\0';
        for (int i = 0; i < LANG_COUNT; i++) {
            if (strcmp(buf, MESSAGES[i].code) == 0) { *out = (lang_t)i; return 1; }
        }
    }
    return 0;
}

/* Localized aliases live beside their catalog so a new locale cannot drift into
 * an unhandled parser branch. The English canonical names stay in main's
 * explicit branches and never infer a non-English UI language. */
static int localized_help_alias(const char *arg, lang_t *out) {
    for (int i = LANG_EN + 1; i < LANG_COUNT; i++) {
        if (MESSAGES[i].help_alias && strcmp(arg, MESSAGES[i].help_alias) == 0) {
            *out = (lang_t)i;
            return 1;
        }
    }
    return 0;
}

/* Return 1 for a detached localized language option and 2 for its =VALUE form.
 * The catalog's own locale is inferred in either case; an explicit value still
 * wins later, matching the normal --lang precedence rule. */
static int localized_lang_option(const char *arg, lang_t *out, const char **value) {
    for (int i = LANG_EN + 1; i < LANG_COUNT; i++) {
        const char *alias = MESSAGES[i].lang_alias;
        if (!alias) continue;
        size_t n = strlen(alias);
        if (strcmp(arg, alias) == 0) {
            *out = (lang_t)i;
            *value = NULL;
            return 1;
        }
        if (strncmp(arg, alias, n) == 0 && arg[n] == '=') {
            *out = (lang_t)i;
            *value = arg + n + 1;
            return 2;
        }
    }
    return 0;
}

/* Resolve UI language. Precedence (highest first): explicit request (--lang or
 * a localized alias) > ROMANTIC_COLLATION_LANG > LC_ALL > LC_MESSAGES > LANG >
 * English. An unsupported EXPLICIT app request WARNs (non-fatal in prepare
 * phase; enforce phase would make it fatal) and falls back to English; ambient
 * env locales fall back SILENTLY so a foreign host locale never spams stderr. */
static lang_t resolve_lang(const char *explicit_code) {
    lang_t lang;
    if (explicit_code && explicit_code[0]) {
        if (lang_from_code(explicit_code, &lang)) return lang;
        fprintf(stderr, "collate: WARN i18n missing-locale '%s' (falling back to English)\n",
                explicit_code);
        return LANG_EN;
    }
    const char *app = getenv("ROMANTIC_COLLATION_LANG");
    if (app && app[0]) {
        if (lang_from_code(app, &lang)) return lang;
        fprintf(stderr, "collate: WARN i18n missing-locale '%s' (falling back to English)\n", app);
        return LANG_EN;
    }
    const char *ambient[3];
    ambient[0] = getenv("LC_ALL");
    ambient[1] = getenv("LC_MESSAGES");
    ambient[2] = getenv("LANG");
    for (int i = 0; i < 3; i++) {
        if (ambient[i] && ambient[i][0] && lang_from_code(ambient[i], &lang)) return lang;
    }
    return LANG_EN;
}

static int print_help(lang_t lang) {
    fputs(MESSAGES[lang].help_text, stdout);
    return 0;
}

static int print_about(lang_t lang) {
    printf("collate %s (%s-%s) — %s\n",
           rcol_version(), RCOL_OS, RCOL_ARCH, MESSAGES[lang].about_desc);
    return 0;
}

/* Read an entire stream into a heap buffer. Caller frees *out_buf.
 * Returns 0 on success, -1 on error (message to stderr). */
static int read_all(FILE *f, const char *name, uint8_t **out_buf, size_t *out_len) {
    size_t cap = 1 << 16;
    size_t len = 0;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) {
        fputs("collate: out of memory\n", stderr);
        return -1;
    }
    for (;;) {
        if (len == cap) {
            size_t ncap = cap * 2;
            uint8_t *nb = (uint8_t *)realloc(buf, ncap);
            if (!nb) {
                free(buf);
                fputs("collate: out of memory\n", stderr);
                return -1;
            }
            buf = nb;
            cap = ncap;
        }
        size_t got = fread(buf + len, 1, cap - len, f);
        len += got;
        if (got == 0) {
            if (ferror(f)) {
                fprintf(stderr, "collate: read error on '%s': %s\n", name, strerror(errno));
                free(buf);
                return -1;
            }
            break; /* EOF */
        }
    }
    *out_buf = buf;
    *out_len = len;
    return 0;
}

typedef struct {
    const uint8_t *line; /* points into the input buffer (not NUL-terminated) */
    size_t line_len;
    uint8_t *key; /* owned sort key */
    size_t key_len;
} row_t;

typedef size_t (*sort_key_fn)(const rcol_collator *, const uint8_t *, size_t,
                              uint8_t *, size_t);

typedef enum {
    SORT_KEY_OK = 0,
    SORT_KEY_ALLOC_FAILED,
    SORT_KEY_BUILD_FAILED,
} sort_key_status;

/* Build one owned key and reject the FFI's zero-length failure sentinel. The
 * injected function keeps this adapter error path mechanically testable. */
static sort_key_status build_sort_key(sort_key_fn get_sort_key,
                                      const rcol_collator *coll,
                                      const uint8_t *src, size_t src_len,
                                      uint8_t **out_key, size_t *out_len) {
    *out_key = NULL;
    *out_len = 0;
    if (src_len > (SIZE_MAX - 16) / 6) return SORT_KEY_ALLOC_FAILED;

    size_t cap = src_len * 6 + 16;
    uint8_t *key = (uint8_t *)malloc(cap);
    if (!key) return SORT_KEY_ALLOC_FAILED;

    size_t need = get_sort_key(coll, src, src_len, key, cap);
    if (need == 0) {
        free(key);
        return SORT_KEY_BUILD_FAILED;
    }
    if (need > cap) {
        uint8_t *grown = (uint8_t *)realloc(key, need);
        if (!grown) {
            free(key);
            return SORT_KEY_ALLOC_FAILED;
        }
        key = grown;
        cap = need;
        need = get_sort_key(coll, src, src_len, key, cap);
        if (need == 0 || need > cap) {
            free(key);
            return SORT_KEY_BUILD_FAILED;
        }
    }

    *out_key = key;
    *out_len = need;
    return SORT_KEY_OK;
}

static const rcol_collator *g_coll; /* used by qsort comparator */

/* Order by sort-key memcmp; break ties by raw line bytes for determinism. */
static int cmp_rows(const void *pa, const void *pb) {
    const row_t *a = (const row_t *)pa;
    const row_t *b = (const row_t *)pb;
    size_t n = a->key_len < b->key_len ? a->key_len : b->key_len;
    int c = memcmp(a->key, b->key, n);
    if (c != 0) return c;
    if (a->key_len != b->key_len) return a->key_len < b->key_len ? -1 : 1;
    /* keys equal: stable-ish tie-break on the raw line */
    size_t m = a->line_len < b->line_len ? a->line_len : b->line_len;
    c = memcmp(a->line, b->line, m);
    if (c != 0) return c;
    if (a->line_len != b->line_len) return a->line_len < b->line_len ? -1 : 1;
    return 0;
}

/* Write the completed sort as one checked stream operation sequence. Checking
 * the final flush catches buffered failures such as a full output device. */
static int write_rows(FILE *out, const row_t *rows, size_t count) {
    for (size_t k = 0; k < count; k++) {
        if (rows[k].line_len > 0
            && fwrite(rows[k].line, 1, rows[k].line_len, out) != rows[k].line_len) {
            return -1;
        }
        if (fputc('\n', out) == EOF) return -1;
    }
    if (fflush(out) == EOF) return -1;
    return ferror(out) ? -1 : 0;
}

/* Locate the (1-based) Nth field of `line` when split on the `sep` substring,
 * returning the field's [ptr,len) via out-params. With no separator (sep NULL
 * or empty) or n < 1, the whole line is the field. A line with fewer than n
 * fields yields an empty field (sorts as empty — first). Naive substring search
 * (separators are short in practice). Kept in the C CLI so the Zig core stays
 * field-agnostic — the hexagonal boundary is preserved. */
static void extract_field(const uint8_t *line, size_t line_len,
                          const char *sep, size_t sep_len, long n,
                          const uint8_t **fptr, size_t *flen) {
    if (!sep || sep_len == 0 || n < 1) {
        *fptr = line;
        *flen = line_len;
        return;
    }
    size_t field_start = 0;
    for (long field = 1; field < n; field++) {
        const uint8_t *hit = NULL;
        for (size_t i = field_start; i + sep_len <= line_len; i++) {
            if (memcmp(line + i, sep, sep_len) == 0) { hit = line + i; break; }
        }
        if (!hit) { /* fewer than n fields => empty field */
            *fptr = line + line_len;
            *flen = 0;
            return;
        }
        field_start = (size_t)(hit - line) + sep_len;
    }
    for (size_t i = field_start; i + sep_len <= line_len; i++) {
        if (memcmp(line + i, sep, sep_len) == 0) {
            *fptr = line + field_start;
            *flen = i - field_start;
            return;
        }
    }
    *fptr = line + field_start;
    *flen = (field_start <= line_len) ? (line_len - field_start) : 0;
}

static int cmd_sort(const char *path, uint32_t options,
                    const char *sep, size_t sep_len, long key_field) {
    FILE *f = stdin;
    int close_f = 0;
    if (path && strcmp(path, "-") != 0 && strcmp(path, "@stdin") != 0) {
        f = fopen(path, "rb");
        if (!f) {
            fprintf(stderr, "collate: cannot open '%s': %s\n", path, strerror(errno));
            return 1;
        }
        close_f = 1;
    }

    uint8_t *data = NULL;
    size_t data_len = 0;
    const char *name = close_f ? path : "<stdin>";
    int rc = read_all(f, name, &data, &data_len);
    if (close_f) fclose(f);
    if (rc != 0) return 1;

    /* Split into lines on '\n'. A trailing line without '\n' still counts. */
    size_t nlines = 0;
    for (size_t i = 0; i < data_len; i++) {
        if (data[i] == '\n') nlines++;
    }
    if (data_len > 0 && data[data_len - 1] != '\n') nlines++;

    if (nlines == 0) {
        free(data);
        return 0; /* empty input => empty output */
    }

    row_t *rows = (row_t *)calloc(nlines, sizeof(row_t));
    if (!rows) {
        free(data);
        fputs("collate: out of memory\n", stderr);
        return 1;
    }

    rcol_collator *coll = rcol_open(options);
    if (!coll) {
        free(rows);
        free(data);
        fputs("collate: failed to open collator\n", stderr);
        return 1;
    }
    g_coll = coll;

    size_t idx = 0;
    size_t start = 0;
    int exit_code = 0;
    for (size_t i = 0; i <= data_len; i++) {
        int at_end = (i == data_len);
        if (at_end && start >= data_len) break; /* no trailing partial line */
        if (at_end || data[i] == '\n') {
            const uint8_t *line = data + start;
            size_t line_len = i - start;
            /* The sort key is computed from the chosen FIELD (whole line when no
             * separator is configured); the original line is still emitted. */
            const uint8_t *ksrc;
            size_t ksrc_len;
            extract_field(line, line_len, sep, sep_len, key_field, &ksrc, &ksrc_len);
            uint8_t *key;
            size_t need;
            sort_key_status key_status = build_sort_key(
                rcol_get_sort_key, coll, ksrc, ksrc_len, &key, &need);
            if (key_status != SORT_KEY_OK) {
                exit_code = 1;
                fputs("collate: out of memory\n", stderr);
                break;
            }
            rows[idx].line = line;
            rows[idx].line_len = line_len;
            rows[idx].key = key;
            rows[idx].key_len = need;
            idx++;
            start = i + 1;
        }
    }

    if (exit_code == 0) {
        qsort(rows, idx, sizeof(row_t), cmp_rows);
        if (write_rows(stdout, rows, idx) != 0) {
            int write_errno = errno;
            exit_code = 1;
            if (write_errno != 0) {
                fprintf(stderr, "collate: write error on stdout: %s\n",
                        strerror(write_errno));
            } else {
                fputs("collate: write error on stdout\n", stderr);
            }
        }
    }

    for (size_t k = 0; k < idx; k++) free(rows[k].key);
    rcol_close(coll);
    free(rows);
    free(data);
    return exit_code;
}

int main(int argc, char *argv[]) {
    announce_debug_build();

    uint32_t options = 0;
    const char *path = NULL;
    const char *sep = NULL; /* field separator (NULL => whole line) */
    long key_field = 0;     /* 1-based field for -k; 0 => unset */
    int key_set = 0;        /* explicit -k/--key seen */
    int sep_from_flag = 0;  /* -t/--field-separator seen (overrides env) */
    int only_switches = 0;  /* set once we see "--" */
    const char *lang_code = NULL;     /* explicit --lang/--sprache code */
    const char *inferred_lang = NULL; /* from a localized alias (e.g. --hilfe) */
    int want_help = 0, want_about = 0, want_version = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!only_switches && strcmp(a, "--") == 0) {
            only_switches = 1;
            continue;
        }
        if (!only_switches && a[0] == '-' && a[1] != '\0' &&
            !(strcmp(a, "-") == 0)) {
            lang_t localized_lang;
            const char *localized_value;
            int localized_lang_form = localized_lang_option(
                a, &localized_lang, &localized_value);
            if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
                want_help = 1;
            } else if (localized_help_alias(a, &localized_lang)) {
                /* A localized help alias infers that catalog; an explicit --lang
                 * still wins. Alias names must stay disjoint from English
                 * canonical option names (see the i18n skill's collision rule). */
                want_help = 1;
                if (!inferred_lang) inferred_lang = MESSAGES[localized_lang].code;
            } else if (strcmp(a, "--about") == 0) {
                want_about = 1;
            } else if (strcmp(a, "--version") == 0) {
                want_version = 1;
            } else if (strcmp(a, "--lang") == 0 || localized_lang_form == 1) {
                if (i + 1 >= argc) {
                    fprintf(stderr, "collate: %s requires a language code\n", a);
                    return 2;
                }
                lang_code = argv[++i];
                if (localized_lang_form == 1 && !inferred_lang) {
                    inferred_lang = MESSAGES[localized_lang].code;
                }
            } else if (strncmp(a, "--lang=", 7) == 0) {
                lang_code = a + 7;
            } else if (localized_lang_form == 2) {
                lang_code = localized_value;
                if (!inferred_lang) inferred_lang = MESSAGES[localized_lang].code;
            } else if (strcmp(a, "-c") == 0 || strcmp(a, "--code-point") == 0) {
                options |= RCOL_CODE_POINT;
            } else if (strcmp(a, "-d") == 0 || strcmp(a, "--decimal") == 0
                       || strcmp(a, "--decimals") == 0 || strcmp(a, "--dec") == 0) {
                options |= RCOL_DECIMAL;
                options &= ~(uint32_t)RCOL_DECIMAL_COMMA;
            } else if (strcmp(a, "-s") == 0 || strcmp(a, "--scientific") == 0
                       || strcmp(a, "--sci") == 0) {
                options |= RCOL_SCIENTIFIC;
            } else if (strcmp(a, "--roman") == 0) {
                options |= RCOL_ROMAN;
            } else if (strcmp(a, "-n") == 0 || strcmp(a, "--numeric") == 0
                       || strcmp(a, "--num") == 0) {
                options |= RCOL_SCIENTIFIC | RCOL_DECIMAL;
                options &= ~(uint32_t)RCOL_DECIMAL_COMMA;
            } else if (strncmp(a, "--scientific=", 13) == 0
                       || strncmp(a, "--sci=", 6) == 0
                       || strncmp(a, "--numeric=", 10) == 0
                       || strncmp(a, "--num=", 6) == 0) {
                /* Same SEP grammar as --decimal; --numeric also turns on
                 * digit-group absorption, --scientific does not. */
                const char *sep = strchr(a, '=') + 1;
                options |= RCOL_SCIENTIFIC;
                if (a[2] == 'n') options |= RCOL_DECIMAL;
                if (strcmp(sep, ".") == 0) {
                    options &= ~(uint32_t)RCOL_DECIMAL_COMMA;
                } else if (strcmp(sep, ",") == 0) {
                    options |= RCOL_DECIMAL_COMMA;
                } else {
                    fprintf(stderr,
                            "collate: decimal separator must be '.' or ',' "
                            "(got \"%s\")\n", sep);
                    return 2;
                }
            } else if (strncmp(a, "--decimal=", 10) == 0
                       || strncmp(a, "--decimals=", 11) == 0
                       || strncmp(a, "--dec=", 6) == 0) {
                /* Attached form only: a detached value would be ambiguous with
                 * the positional FILE argument. */
                const char *sep = strchr(a, '=') + 1;
                if (strcmp(sep, ".") == 0) {
                    options |= RCOL_DECIMAL;
                    options &= ~(uint32_t)RCOL_DECIMAL_COMMA;
                } else if (strcmp(sep, ",") == 0) {
                    options |= RCOL_DECIMAL | RCOL_DECIMAL_COMMA;
                } else {
                    fprintf(stderr,
                            "collate: --decimal separator must be '.' or ',' "
                            "(got \"%s\")\n", sep);
                    return 2;
                }
            } else if (strcmp(a, "--version-sort") == 0) {
                /* The explicit form of the default. Present so a later argument
                 * can override an earlier numeric mode, per the CLI convention. */
                options &= ~((uint32_t)RCOL_DECIMAL
                             | (uint32_t)RCOL_DECIMAL_COMMA
                             | (uint32_t)RCOL_SCIENTIFIC);
            } else if (strcmp(a, "--field-separator") == 0) {
                if (i + 1 >= argc) {
                    fputs("collate: --field-separator requires an argument\n", stderr);
                    return 2;
                }
                sep = argv[++i];
                sep_from_flag = 1;
            } else if (strncmp(a, "--field-separator=", 18) == 0) {
                sep = a + 18;
                sep_from_flag = 1;
            } else if (a[1] == 't') { /* -t or -tSEP (SEP may be empty=>whole line) */
                if (a[2] != '\0') {
                    sep = a + 2;
                } else if (i + 1 < argc) {
                    sep = argv[++i];
                } else {
                    fputs("collate: -t requires an argument\n", stderr);
                    return 2;
                }
                sep_from_flag = 1;
            } else if (strcmp(a, "--key") == 0 || strncmp(a, "--key=", 6) == 0 ||
                       a[1] == 'k') {
                const char *val;
                if (strcmp(a, "--key") == 0) {
                    if (i + 1 >= argc) {
                        fputs("collate: --key requires an argument\n", stderr);
                        return 2;
                    }
                    val = argv[++i];
                } else if (strncmp(a, "--key=", 6) == 0) {
                    val = a + 6;
                } else { /* -k or -kN */
                    if (a[2] != '\0') {
                        val = a + 2;
                    } else if (i + 1 < argc) {
                        val = argv[++i];
                    } else {
                        fputs("collate: -k requires an argument\n", stderr);
                        return 2;
                    }
                }
                char *endp;
                long v = strtol(val, &endp, 10);
                if (*val == '\0' || *endp != '\0' || v < 1) {
                    fprintf(stderr, "collate: invalid field number '%s'\n", val);
                    return 2;
                }
                key_field = v;
                key_set = 1;
            } else {
                fprintf(stderr, "collate: unknown option '%s' (try --help)\n", a);
                return 2;
            }
        } else {
            /* positional: input path ('-'/'@stdin' handled in cmd_sort) */
            if (path != NULL) {
                fprintf(stderr, "collate: unexpected extra argument '%s'\n", a);
                return 2;
            }
            path = a;
        }
    }

    /* Resolve the UI language once (all args parsed => later args win), then
     * handle terminal actions. Help/version/about must not be blocked by sort
     * argument validation, so they dispatch before it. */
    lang_t lang = resolve_lang(lang_code ? lang_code : inferred_lang);
    if (want_help) return print_help(lang);
    if (want_version) {
        printf("%s\n", rcol_version());
        return 0;
    }
    if (want_about) return print_about(lang);

    /* Field separator precedence: -t/--field-separator wins; else the
     * COLLATE_FIELD_SEP env default; else whole-line (IFS-style). */
    if (!sep_from_flag) {
        const char *env = getenv("COLLATE_FIELD_SEP");
        if (env && env[0] != '\0') sep = env;
    }
    size_t sep_len = sep ? strlen(sep) : 0;

    if (key_set && sep_len == 0) {
        fputs("collate: -k/--key requires a field separator "
              "(-t/--field-separator or COLLATE_FIELD_SEP)\n", stderr);
        return 2;
    }
    /* A separator with no explicit -k sorts by field 1. */
    if (sep_len > 0 && !key_set) key_field = 1;

    return cmd_sort(path, options, sep, sep_len, key_field);
}
