#!/usr/bin/env python3
"""Check that every Russian Swift message has an English catalog entry."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
CYRILLIC = re.compile('[А-Яа-яЁё]')


def string_at(source, start):
    i, key, count = start + 1, '', 0
    while i < len(source):
        ch = source[i]
        if ch == '"':
            return key, i + 1
        if ch == '\\' and i + 1 < len(source):
            if source[i + 1] == '(':
                i, depth = i + 2, 1
                while i < len(source) and depth:
                    if source[i] == '"':
                        _, i = string_at(source, i)
                        continue
                    if source[i] == '(':
                        depth += 1
                    elif source[i] == ')':
                        depth -= 1
                    i += 1
                if depth:
                    raise ValueError('Unclosed interpolation')
                key += '{' + str(count) + '}'
                count += 1
                continue
            key += {'n': '\n', 't': '\t', 'r': '\r', '0': '\0'}.get(source[i + 1], source[i + 1])
            i += 2
            continue
        key += ch
        i += 1
    raise ValueError('Unclosed string')


def strings(source):
    i = 0
    while i < len(source):
        if source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end + 1
        elif source[i] == '"':
            value, i = string_at(source, i)
            yield value
        else:
            i += 1


def main():
    catalog = list(strings((ROOT / 'Sources/AppLocalization/EnglishCatalog.swift').read_text()))
    assert len(catalog) % 2 == 0
    translations = dict(zip(catalog[::2], catalog[1::2]))
    assert len(translations) == len(catalog) // 2, 'Duplicate catalog key'
    for key, english in translations.items():
        assert not CYRILLIC.search(english), f'Untranslated value: {key}'
        assert set(re.findall(r'\{\d+\}', key)) == set(re.findall(r'\{\d+\}', english)), f'Placeholder mismatch: {key}'
    missing = []
    for file in (ROOT / 'Sources').rglob('*.swift'):
        if 'AppLocalization' in file.parts:
            continue
        for value in strings(file.read_text()):
            if CYRILLIC.search(value) and value != 'Русский' and value not in translations:
                missing.append((str(file.relative_to(ROOT)), value))
    for file, key in missing:
        print(f'Missing translation in {file}: {key}')
    assert not missing, f'{len(missing)} messages are missing translations'
    print(f'{len(translations)} English translations verified; all source messages covered.')


if __name__ == '__main__':
    main()
