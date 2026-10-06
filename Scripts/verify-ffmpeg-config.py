#!/usr/bin/env python3
"""Validate generated FFmpeg configuration, not a proposed configure recipe."""
import argparse
import re
from pathlib import Path


def verify(header, makefile):
    defines = dict(re.findall(r'^#define (CONFIG_\w+) ([01])$', header, re.M))
    if not defines or not all(k in defines for k in ('CONFIG_GPL', 'CONFIG_NONFREE', 'CONFIG_SDL2')):
        raise ValueError('incomplete generated config.h')
    forbidden = re.compile(r'CONFIG_(?:GPL|GPLV3|NONFREE|VERSION3|LIB.*|SDL.*|ZLIB|BZLIB|LZMA|OPENSSL|GNUTLS|MBEDTLS|GCRYPT|GMP|LADSPA|LV2)$')
    bad = [k for k, v in defines.items() if v == '1' and forbidden.fullmatch(k)]
    if bad:
        raise ValueError('unexpected enabled dependencies: ' + ', '.join(bad))
    for key, value in defines.items():
        if re.search(r'^' + re.escape(key) + r'=yes$', makefile, re.M) and value != '1':
            raise ValueError('config.h/config.mak disagree: ' + key)
        if re.search(r'^!' + re.escape(key) + r'=yes$', makefile, re.M) and value != '0':
            raise ValueError('config.h/config.mak disagree: ' + key)
    flags = re.search(r'^FFMPEG_CONFIGURATION=(.*)$', makefile, re.M)
    license_text = re.search(r'^#define FFMPEG_LICENSE "([^"]+)"$', header, re.M)
    if not flags or '--disable-autodetect' not in flags[1] or not license_text:
        raise ValueError('missing configuration/license or autodetect not disabled')
    if license_text[1] != 'LGPL version 2.1 or later':
        raise ValueError('unexpected generated license: ' + license_text[1])
    system = ('APPKIT', 'AVFOUNDATION', 'COREIMAGE', 'ICONV', 'SECURETRANSPORT', 'AUDIOTOOLBOX', 'VIDEOTOOLBOX', 'VAAPI', 'VDPAU')
    enabled = [x for x in system if defines.get('CONFIG_' + x) == '1']
    return '\n'.join(('FFMPEG_CONFIGURATION=' + flags[1], 'FFMPEG_LICENSE=' + license_text[1],
                      'external optional dependencies: disabled',
                      'enabled system integrations: ' + (', '.join(enabled) or 'none')))


def selftest():
    header = '#define FFMPEG_LICENSE "LGPL version 2.1 or later"\n' + ''.join(
        '#define CONFIG_' + x + ' 0\n' for x in ('GPL', 'NONFREE', 'SDL2'))
    mak = 'FFMPEG_CONFIGURATION=--disable-autodetect\n!CONFIG_GPL=yes\n!CONFIG_NONFREE=yes\n!CONFIG_SDL2=yes\n'
    verify(header, mak)
    for name in ('GPL', 'NONFREE', 'SDL2'):
        try:
            verify(header.replace('CONFIG_' + name + ' 0', 'CONFIG_' + name + ' 1'), mak)
        except ValueError:
            continue
        raise ValueError('guard failed for ' + name)
    print('PASS: FFmpeg configuration guard (valid/GPL/nonfree/SDL2)')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('config_h', nargs='?')
    parser.add_argument('config_mak', nargs='?')
    parser.add_argument('--selftest', action='store_true')
    args = parser.parse_args()
    try:
        if args.selftest:
            selftest()
        else:
            if not args.config_h or not args.config_mak:
                parser.error('config.h and config.mak required')
            print(verify(Path(args.config_h).read_text(), Path(args.config_mak).read_text()))
    except (ValueError, OSError) as error:
        parser.exit(1, 'FAIL: ' + str(error) + '\n')
