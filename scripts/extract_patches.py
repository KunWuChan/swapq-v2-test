#!/usr/bin/env python3
"""Extract kernel patches from swap.txt email-format file."""
import re, os, sys

SWAP_TXT = sys.argv[1] if len(sys.argv) > 1 else '../swap.txt'
OUT_DIR = sys.argv[2] if len(sys.argv) > 2 else '../patches'

os.makedirs(OUT_DIR, exist_ok=True)

with open(SWAP_TXT, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

# Find all attachment boundaries
attachments = list(re.finditer(
    r'^==== Attachment (\d+) \((.+?)\) ====$',
    content, re.MULTILINE
))

print(f'Found {len(attachments)} attachments')

# Map attachment numbers to their content ranges
for i, m in enumerate(attachments):
    num = int(m.group(1))
    path = m.group(2)
    start = m.end() + 1  # skip the newline after ====
    end = attachments[i+1].start() if i+1 < len(attachments) else len(content)
    body = content[start:end].rstrip('\n') + '\n'

    # Determine filename
    basename = os.path.basename(path)
    if basename.endswith('.patch') or basename.endswith('.txt'):
        pass  # keep original name
    elif path.endswith('.md'):
        basename = basename.replace('.md', '.txt')
    else:
        # For attachments without extension, infer from path
        basename = basename

    out_path = os.path.join(OUT_DIR, basename)
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write(body)
    print(f'  [{num}] {basename} ({len(body)} bytes)')

print(f'\nExtracted to: {OUT_DIR}')
