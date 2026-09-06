"""Inspect the immutable DEB and hash each payload file without executing code."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import tarfile

if not __debug__:
    raise SystemExit('Validation must run with Python assertions enabled.')

EXPECTED = 'd858bff4cf38db047f2d1c5ae40600df53ec0870313e6d2715d5678449e5eb22'

def elf_metadata(data):
    if data[:4] != b'\x7fELF':
        return None
    assert data[4:6] == b'\x02\x01', 'expected ELF64 little endian'
    machine = struct.unpack_from('<H', data, 18)[0]
    phoff = struct.unpack_from('<Q', data, 32)[0]
    phentsize, phnum = struct.unpack_from('<HH', data, 54)
    segments = [struct.unpack_from('<IIQQQQQQ', data, phoff + i * phentsize) for i in range(phnum)]
    interpreter = next((data[offset:offset + filesz].rstrip(b'\0').decode('ascii') for kind, flags, offset, vaddr, paddr, filesz, memsz, align in segments if kind == 3), None)
    tags = []
    for kind, flags, offset, vaddr, paddr, filesz, memsz, align in segments:
        if kind == 2:
            for pos in range(offset, offset + filesz, 16):
                tag, value = struct.unpack_from('<qQ', data, pos)
                if tag == 0:
                    break
                tags.append((tag, value))
    needed = []
    straddr = next((value for tag, value in tags if tag == 5), None)
    if straddr is not None:
        base = next(offset + straddr - vaddr for kind, flags, offset, vaddr, paddr, filesz, memsz, align in segments if kind == 1 and vaddr <= straddr < vaddr + filesz)
        for tag, value in tags:
            if tag == 1:
                end = data.index(b'\0', base + value)
                needed.append(data[base + value:end].decode('ascii'))
    return {'class': 64, 'machine': machine, 'architecture': 'x86_64' if machine == 62 else str(machine), 'interpreter': interpreter, 'needed': needed, 'glibcVersions': sorted(set(v.decode() for v in re.findall(rb'GLIBC_[0-9]+\.[0-9]+(?:\.[0-9]+)?', data)))}

def audit(path):
    data = path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == EXPECTED, 'DEB SHA-256 mismatch'
    assert len(data) == 146881864
    assert data[:8] == b'!<arch>\n'
    parts = {}
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        assert header[58:60] == b'`\n'
        name = header[:16].decode().strip().rstrip('/')
        size = int(header[48:58])
        parts[name] = data[offset + 60:offset + 60 + size]
        offset += 60 + size + size % 2
    result = {'debSha256': EXPECTED, 'debBytes': len(data), 'files': {}, 'elf': {}, 'control': {}}
    with tarfile.open(fileobj=io.BytesIO(parts['control.tar.xz']), mode='r:xz') as archive:
        for member in archive:
            if member.isfile() and member.name.removeprefix('./') == 'control':
                result['control']['text'] = archive.extractfile(member).read().decode()
    with tarfile.open(fileobj=io.BytesIO(parts['data.tar.xz']), mode='r|xz') as archive:
        for member in archive:
            name = member.name.removeprefix('./')
            assert not name.startswith('/') and '..' not in Path(name).parts
            if member.isfile():
                content = archive.extractfile(member).read()
                result['files'][name] = {'sha256': hashlib.sha256(content).hexdigest(), 'bytes': len(content), 'mode': oct(member.mode)}
                elf = elf_metadata(content)
                if elf:
                    result['elf'][name] = elf
            elif member.issym():
                result['files'][name] = {'symlink': member.linkname}
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('deb', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = audit(args.deb)
    args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'debSha256': result['debSha256'], 'payloadFiles': len(result['files']), 'elf': result['elf']}, indent=2))
