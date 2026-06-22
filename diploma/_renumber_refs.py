"""Перенумерация источников ВКР по порядку первого упоминания в тексте.

Режим report (по умолчанию): печатает отображение и аномалии, файл не меняет.
Режим apply: переписывает ссылки в тексте и список источников.
    python _renumber_refs.py apply
"""
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")
PATH = "ВКР.md"
APPLY = len(sys.argv) > 1 and sys.argv[1] == "apply"

text = open(PATH, encoding="utf-8").read()
lines = text.split("\n")

# --- границы блока списка источников ---
start = next(i for i, l in enumerate(lines)
             if l.strip() == "## СПИСОК ИСПОЛЬЗОВАННЫХ ИСТОЧНИКОВ")
end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith("## "))

ref_re = re.compile(r"^(\d+)\.\s+(.*)$")
refs = {}
for i in range(start + 1, end):
    m = ref_re.match(lines[i].strip())
    if m:
        refs[int(m.group(1))] = m.group(2)

# --- регэксп цитаты: [N], [N, M], [N–M]; диапазон скобок [N]–[M] обрабатываем
#     отдельным предсканом ниже ---
cite_re = re.compile(r"\[(\d+(?:\s*[,–-]\s*\d+)*)\]")
bracket_range_re = re.compile(r"\[(\d+)\]\s*[–-]\s*\[(\d+)\]")


def expand_inner(inner):
    """'11–13' -> [11,12,13]; '8, 9' -> [8,9]; '5' -> [5]."""
    nums = []
    for part in inner.split(","):
        part = part.strip()
        m = re.match(r"^(\d+)\s*[–-]\s*(\d+)$", part)
        if m:
            nums += list(range(int(m.group(1)), int(m.group(2)) + 1))
        else:
            nums.append(int(part))
    return nums


# --- сбор порядка первого упоминания (пропуская код-блоки и сам список) ---
order, seen, occ = [], set(), []
in_code = False
for i, l in enumerate(lines):
    if l.lstrip().startswith("```"):
        in_code = not in_code
        continue
    if in_code or (start <= i < end):
        continue
    # сначала диапазоны скобок [N]–[M]
    for m in bracket_range_re.finditer(l):
        a, b = int(m.group(1)), int(m.group(2))
        nums = list(range(a, b + 1))
        occ.append((i + 1, m.group(0), nums))
        for n in nums:
            if n not in seen:
                seen.add(n); order.append(n)
    # затем одиночные/списковые цитаты, не входящие в диапазон скобок
    line_wo_ranges = bracket_range_re.sub("", l)
    for m in cite_re.finditer(line_wo_ranges):
        nums = expand_inner(m.group(1))
        occ.append((i + 1, m.group(0), nums))
        for n in nums:
            if n not in seen:
                seen.add(n); order.append(n)

mapping = {old: i + 1 for i, old in enumerate(order)}

print("Источников в списке:", len(refs), "->", sorted(refs))
print("Появилось в тексте:", len(order))
print("В списке, но НЕ процитировано:", sorted(set(refs) - seen))
print("Процитировано, но НЕТ в списке:", sorted(seen - set(refs)))
print("\nОтображение старый -> новый:")
for old in sorted(mapping):
    print(f"  [{old}] -> [{mapping[old]}]")
print(f"\nВсего вхождений цитат: {len(occ)}")
print("Первые 60 вхождений (строка, токен, номера):")
for ln, tok, nums in occ[:60]:
    print(f"  {ln}: {tok} -> {nums}")

if not APPLY:
    print("\n[report only] для применения: python _renumber_refs.py apply")
    sys.exit(0)

# --------------------------------------------------------------------------- #
# Применение: переписать цитаты и переупорядочить список источников
# --------------------------------------------------------------------------- #


def fmt_new(old_nums):
    """Список старых номеров -> строка новых: сортировка, сжатие 3+ подряд в a–b."""
    new = sorted(mapping[n] for n in old_nums)
    parts, i = [], 0
    while i < len(new):
        j = i
        while j + 1 < len(new) and new[j + 1] == new[j] + 1:
            j += 1
        run = new[i:j + 1]
        if len(run) >= 3:                       # 3+ подряд -> диапазон
            parts.append(f"{run[0]}–{run[-1]}")
        else:                                   # иначе — по одному
            parts += [str(x) for x in run]
        i = j + 1
    return ", ".join(parts)


def repl_token(m):
    return f"[{fmt_new(expand_inner(m.group(1)))}]"


def repl_bracket_range(m):
    a, b = int(m.group(1)), int(m.group(2))
    return f"[{fmt_new(list(range(a, b + 1)))}]"


rewrites = 0
new_lines = list(lines)
in_code = False
for i, l in enumerate(lines):
    if l.lstrip().startswith("```"):
        in_code = not in_code
        continue
    if in_code or (start <= i < end):
        continue
    nl = bracket_range_re.sub(repl_bracket_range, l)
    nl = cite_re.sub(repl_token, nl)
    if nl != l:
        rewrites += 1
        new_lines[i] = nl

# Переупорядоченный список источников
inv = {new: old for old, new in mapping.items()}
block = [lines[start], ""]
for new in range(1, len(order) + 1):
    block.append(f"{new}. {refs[inv[new]]}")
block += ["", "---", ""]

result = new_lines[:start] + block + new_lines[end:]
open(PATH, "w", encoding="utf-8", newline="\n").write("\n".join(result))
print(f"\n[apply] строк с переписанными цитатами: {rewrites}; "
      f"список источников переупорядочен ({len(order)} позиций). Записано в {PATH}.")
