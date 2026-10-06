#!/usr/bin/env python3
# =============================================================================
# check-abi-crc.py —— 内核 ABI 预检：把 ROM 里 vendor 模块的符号 CRC 和自编内核比对
#
# 为什么需要它（这是"刷进去卡在开机 logo"的根因防御）：
#   Android GKI 的内核与 vendor 模块是【分离编译】的。ROM 里 /vendor/lib/modules/*.ko
#   在编译时把"所需符号的 CRC"写进了模块的 __versions 段。内核启动加载模块时，
#   会拿自己算出的 CRC 去比对；不一致就直接拒绝加载。
#
#   CRC 由 genksyms 从【类型定义】算出来 —— 所以只要自编内核里某个被导出符号
#   签名涉及的结构体布局与官方不同（例如：
#       CONFIG_NF_TABLES=y      -> struct net 多出 netns_nftables nft;
#       CONFIG_SYSVIPC=y        -> struct task_struct 多出 sysvsem / sysvshm
#   ），该符号的 CRC 就变了 → 模块集体拒载 → vendor init 起不来 →
#   显示驱动模块也没加载 → 【屏幕永远停在米标】，且没有任何日志。
#
#   这类问题不报编译错、不 panic，只能靠 ABI 比对提前发现。
#
# 用法：
#   1) 生成基线（从设备上拉下来的 .ko）：
#        python scripts/check-abi-crc.py baseline abi-baseline/ -o abi-baseline/abi-crcs.txt
#   2) 编译后核对（需要一个 Module.symvers）：
#        python scripts/check-abi-crc.py check <out>/Module.symvers \
#               -b abi-baseline/abi-crcs.txt
#      退出码 0 = ABI 兼容，可以刷；非 0 = 有符号 CRC 不一致，别刷。
# =============================================================================
import argparse
import os
import re
import struct
import sys

MODULE_NAME_LEN = 56          # MAX_PARAM_PREFIX_LEN
ENTRY_SIZE = 8 + MODULE_NAME_LEN   # struct modversion_info


def read_elf_sections(path):
    """返回 [(name, sh_type, offset, size), ...]（只支持 64 位小端 ELF）。"""
    with open(path, 'rb') as f:
        data = f.read()
    if data[:4] != b'\x7fELF':
        raise ValueError('不是 ELF 文件')
    if data[4] != 2:
        raise ValueError('不是 64 位 ELF')
    if data[5] != 1:
        raise ValueError('不是小端 ELF')
    e_shoff = struct.unpack_from('<Q', data, 0x28)[0]
    e_shentsize = struct.unpack_from('<H', data, 0x3A)[0]
    e_shnum = struct.unpack_from('<H', data, 0x3C)[0]
    e_shstrndx = struct.unpack_from('<H', data, 0x3E)[0]
    if e_shoff == 0 or e_shnum == 0:
        raise ValueError('没有节表')

    def sh(i):
        off = e_shoff + i * e_shentsize
        name, sh_type, _flags, _addr, offset, size = struct.unpack_from('<IIQQQQ', data, off)
        return name, sh_type, offset, size

    _, _, str_off, str_size = sh(e_shstrndx)
    strtab = data[str_off:str_off + str_size]

    def sname(off):
        end = strtab.find(b'\0', off)
        return strtab[off:end].decode('utf-8', 'replace')

    out = []
    for i in range(e_shnum):
        n, t, o, s = sh(i)
        out.append((sname(n), t, o, s))
    return out, data


def parse_versions(path):
    """从 .ko 里取出 __versions 段：{symbol: crc}"""
    sections, data = read_elf_sections(path)
    res = {}
    for name, sh_type, off, size in sections:
        if name != '__versions':
            continue
        if size % ENTRY_SIZE != 0:
            raise ValueError('%s: __versions 大小 %d 不是 %d 的整数倍'
                             % (os.path.basename(path), size, ENTRY_SIZE))
        for i in range(size // ENTRY_SIZE):
            base = off + i * ENTRY_SIZE
            crc = struct.unpack_from('<Q', data, base)[0]
            raw = data[base + 8: base + 8 + MODULE_NAME_LEN]
            sym = raw.split(b'\0', 1)[0].decode('utf-8', 'replace')
            if sym:
                res[sym] = crc
    return res


def parse_symvers(path):
    """解析内核构建产物 Module.symvers -> {symbol: crc}"""
    res = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line.strip():
                continue
            parts = line.split('\t')
            if len(parts) < 2:
                parts = line.split()
            if len(parts) < 2:
                continue
            try:
                crc = int(parts[0], 16)
            except ValueError:
                continue
            res[parts[1]] = crc
    return res


def cmd_baseline(args):
    merged = {}          # sym -> (crc, [modules])
    n_ko = 0
    for root, _dirs, files in os.walk(args.kodir):
        for fn in sorted(files):
            if not fn.endswith('.ko'):
                continue
            p = os.path.join(root, fn)
            try:
                v = parse_versions(p)
            except Exception as e:
                print('  [WARN] %s: %s' % (fn, e), file=sys.stderr)
                continue
            n_ko += 1
            for s, c in v.items():
                if s in merged and merged[s][0] != c:
                    print('  [WARN] %s 与前面模块的 CRC 不一致: %s (0x%08x vs 0x%08x)'
                          % (s, fn, c, merged[s][0]), file=sys.stderr)
                    continue
                merged.setdefault(s, (c, []))[1].append(fn)
    out = args.output or os.path.join(args.kodir, 'abi-crcs.txt')
    with open(out, 'w', encoding='utf-8') as f:
        f.write('# 由 scripts/check-abi-crc.py baseline 生成\n')
        f.write('# 来源：设备 /vendor/lib/modules/*.ko 的 __versions 段\n')
        f.write('# <symbol>\\t<crc_hex>\\t<来源模块>\n')
        for s in sorted(merged):
            crc, mods = merged[s]
            f.write('%s\t0x%08x\t%s\n' % (s, crc, ','.join(mods[:3])))
    print('[+] 扫描了 %d 个 .ko，得到 %d 个符号的 ABI 基线' % (n_ko, len(merged)))
    print('[+] 写入 %s' % out)
    return 0


def cmd_dump_vmlinux(args):
    """从 vmlinux（ELF）里导出"符号 -> CRC"表，输出 Module.symvers 同款格式。

    为什么要从 vmlinux 取，而不是 Module.symvers：
      我们只跑 `make Image`（不编 modules），而 Module.symvers 是 modpost 在为模块
      生成符号版本信息时才产出的 —— 实测只编 Image 时它不存在。但 vmlinux 一定
      存在（Image 就是从它来的），而且 vmlinux 是【完成链接的 ELF】，
      节表齐全、PREL32 已定值，可以直接定位 __ksymtab / __kcrctab。

    原理（5.10 + CONFIG_MODVERSIONS + CONFIG_HAVE_ARCH_PREL32_RELOCATIONS）：
      - `struct kernel_symbol` = 3 个 int32（value_offset / name_offset /
        namespace_offset），偏移都是相对本项自身地址的 PREL32。
      - 每个导出符号会在 `___kcrctab<sec>+<sym>` 放一个 .long __crc_<sym>；
        链接脚本用 KEEP(*(SORT(___kcrctab+*))) 收集，和 __ksymtab 一样按名字排序
        —— 所以两张表是【同序平行数组】，可按索引配对。
      - MODULE_NAME_LEN 之类的细节不影响这里。

    安全性：只接受名字地址落在 __ksymtab_strings* 节内、且形如 C 标识符的条目，
    避免把垃圾 PREL32 值误当成符号名。
    """
    path = args.vmlinux
    f = open(path, 'rb')
    hdr = f.read(64)
    if hdr[:4] != b'\x7fELF':
        print('[FAIL] %s 不是 ELF' % path, file=sys.stderr)
        return 2
    if hdr[4] != 2 or hdr[5] != 1:
        print('[FAIL] 只支持 64 位小端 ELF', file=sys.stderr)
        return 2
    e_shoff = struct.unpack_from('<Q', hdr, 0x28)[0]
    e_shentsize = struct.unpack_from('<H', hdr, 0x3A)[0]
    e_shnum = struct.unpack_from('<H', hdr, 0x3C)[0]
    e_shstrndx = struct.unpack_from('<H', hdr, 0x3E)[0]

    f.seek(e_shoff)
    raw = f.read(e_shentsize * e_shnum)

    def sh(i):
        off = i * e_shentsize
        return struct.unpack_from('<IIQQQQ', raw, off)   # name,type,flags,addr,offset,size

    _n, _t, _fl, str_addr, str_off, str_size = sh(e_shstrndx)
    f.seek(str_off)
    strtab = f.read(str_size)

    def sname(o):
        e = strtab.find(b'\0', o)
        return strtab[o:e].decode('utf-8', 'replace')

    secs = {}
    for i in range(e_shnum):
        n, t, fl, a, o, sz = sh(i)
        secs[sname(n)] = (a, o, sz)

    print('[i] 节数 %d；找到 __ksymtab? %s  __kcrctab? %s  __ksymtab_strings? %s'
          % (e_shnum, '__ksymtab' in secs, '__kcrctab' in secs,
             '__ksymtab_strings' in secs))

    # 允许把名字地址映射回文件偏移的"容器"：所有带地址的节
    ranges = [(a, sz, o) for (a, o, sz) in secs.values() if a and sz]
    # 名字必须落在 __ksymtab_strings*（最严格、最安全）
    name_ranges = [(a, sz, o) for nm, (a, o, sz) in secs.items()
                   if nm.startswith('__ksymtab_strings') and sz]

    def in_ranges(addr, rs):
        for a, sz, o in rs:
            if a <= addr < a + sz:
                return o + (addr - a)
        return None

    def read_cstr(off, maxlen=256):
        f.seek(off)
        b = f.read(maxlen)
        return b.split(b'\0', 1)[0].decode('utf-8', 'replace')

    pat = re.compile(r'^[A-Za-z_][A-Za-z0-9_.]*$')
    pairs = [('__ksymtab', '__kcrctab'),
             ('__ksymtab_gpl', '__kcrctab_gpl'),
             ('__ksymtab_gpl_future', '__kcrctab_gpl_future'),
             ('__ksymtab_unused', '__kcrctab_unused'),
             ('__ksymtab_unused_gpl', '__kcrctab_unused_gpl')]

    out = {}
    layouts = [('PREL32(3xint32)', 12, True), ('绝对指针(3xint64)', 24, False)]
    for ks_name, kc_name in pairs:
        if ks_name not in secs:
            continue
        ks_addr, ks_off, ks_size = secs[ks_name]
        if kc_name not in secs:
            print('[WARN] 缺 %s，跳过 %s' % (kc_name, ks_name), file=sys.stderr)
            continue
        _a, kc_off, kc_size = secs[kc_name]
        f.seek(ks_off)
        ks_raw = f.read(ks_size)
        f.seek(kc_off)
        kc_raw = f.read(kc_size)

        # 取证信息：两张表的条目数。__ksymtab 和 __kcrctab 是"同序平行数组"，
        # 前提是每个导出符号在两张表里都各有一条。条目数一旦不相等，
        # 按索引配对从缺口处开始整体错位 —— Run#10 的 58% CRC 不一致
        # 强烈怀疑就是这个（正在用符号表法交叉验证）。
        print('[i] %s=%d 条目 vs %s=%d 条目 %s'
              % (ks_name, ks_size // 12, kc_name, kc_size // 4,
                 '（一致）' if ks_size // 12 == kc_size // 4
                 else '（!!! 不一致 -> 索引配对从此错位）'))

        best = None
        for lname, entsz, is_prel in layouts:
            n = ks_size // entsz
            if n <= 0:
                continue
            got, table = 0, {}
            for i in range(n):
                base = i * entsz
                if is_prel:
                    name_addr = ks_addr + base + 4 + struct.unpack_from('<i', ks_raw, base + 4)[0]
                else:
                    name_addr = struct.unpack_from('<Q', ks_raw, base + 8)[0]
                o = in_ranges(name_addr, name_ranges) or in_ranges(name_addr, ranges)
                if o is None:
                    continue
                sym = read_cstr(o)
                if not sym or not pat.match(sym):
                    continue
                if (i + 1) * 4 > len(kc_raw):
                    continue
                table[sym] = struct.unpack_from('<I', kc_raw, i * 4)[0]
                got += 1
            print('[i] %s 按 %s 解析：%d 项里认出 %d 个符号' % (ks_name, lname, n, got))
            if best is None or got > best[1]:
                best = (table, got, lname)
        if best and best[1]:
            out.update(best[0])
            print('[i]   -> 采用 %s 的 %d 个符号' % (best[2], best[1]))

    if not out:
        print('[FAIL] 没能从 vmlinux 解析出任何符号 CRC', file=sys.stderr)
        return 2

    # ---- 权威数据源：符号表里的 __crc_<sym> 绝对符号（与 modpost 同源）----
    # `___kcrctab+<sym>` 节里放的是 `.long __crc_<sym>`；链接脚本（.tmp_symversions.lds）
    # 把 __crc_<sym> 定义为绝对符号、值就是 CRC。modpost 读的就是这些符号的 st_value。
    # 直接从 vmlinux 符号表读 __crc_* 同样可以 —— 完全不依赖"两表同序平行"的假设。
    # 上面的索引配对法一旦错位就会得到错误 CRC（Run#10 疑似翻车点），这里交叉验证。
    crc_symtab = {}
    for i in range(e_shnum):
        n, t, fl, a, o, sz = sh(i)
        if t != 2:  # SHT_SYMTAB
            continue
        # 符号表头：name(4) type(4) flags(8) addr(8) offset(8) size(8) link(4) info(4) align(8) entsize(8)
        link = struct.unpack_from('<I', raw, i * e_shentsize + 40)[0]
        _n2, _t2, _f2, _a2, stro, strsz = sh(link)
        f.seek(stro)
        strt = f.read(strsz)
        f.seek(o)
        symtab = f.read(sz)
        entsize = struct.unpack_from('<Q', raw, i * e_shentsize + 56)[0] or 24
        cnt = len(symtab) // entsize
        for j in range(cnt):
            off = j * entsize
            st_name = struct.unpack_from('<I', symtab, off)[0]
            if st_name >= len(strt):
                continue
            e = strt.find(b'\0', st_name)
            nm = strt[st_name:e].decode('utf-8', 'replace')
            if not nm.startswith('__crc_'):
                continue
            st_value = struct.unpack_from('<Q', symtab, off + 8)[0]
            crc_symtab[nm[6:]] = st_value & 0xFFFFFFFF
        print('[i] 符号表法：读到 %d 个 __crc_* 符号' % len(crc_symtab))
        break

    if crc_symtab:
        # 两法交叉验证：把配对法明显错位的证据打出来
        both = set(out) & set(crc_symtab)
        diff = [s for s in both if out[s] != crc_symtab[s]]
        print('[i] 交叉验证：两法共同符号 %d 个，CRC 不同 %d 个%s'
              % (len(both), len(diff),
                 ' —— 配对法存在错位，已改用符号表法！' if diff else '（两法一致）'))
        for s in sorted(diff)[:10]:
            print('[i]   配对法错位样例: %-40s 配对=0x%08x 符号表=0x%08x'
                  % (s, out[s], crc_symtab[s]))
        out = dict(crc_symtab)

    with open(args.output, 'w', encoding='utf-8') as fo:
        for s in sorted(out):
            fo.write('0x%08x\t%s\tvmlinux\tEXPORT_SYMBOL\n' % (out[s], s))
    print('[+] 写入 %s（%d 个符号）' % (args.output, len(out)))
    return 0


def cmd_check(args):
    base = {}
    with open(args.baseline, encoding='utf-8') as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            parts = line.rstrip('\n').split('\t')
            base[parts[0]] = int(parts[1], 16)

    ours = parse_symvers(args.symvers)
    print('[i] 基线符号数: %d   Module.symvers 符号数: %d' % (len(base), len(ours)))

    common = set(base) & set(ours)
    missing = sorted(set(base) - set(ours))       # ROM 需要但我们的内核没导出
    bad = sorted(s for s in common if base[s] != ours[s])

    print('[i] 共同符号: %d' % len(common))
    if bad:
        print('\n[FAIL] 有 %d 个符号 CRC 不一致 —— 内核 ABI 与 ROM 的 vendor 模块不兼容！'
              % len(bad))
        print('       刷进去会卡在开机 logo（模块全部拒载）。')
        print('       %-44s %-12s %s' % ('符号', 'ROM 期望', '我们的内核'))
        for s in bad[:60]:
            print('       %-44s 0x%08x   0x%08x' % (s, base[s], ours[s]))
        if len(bad) > 60:
            print('       ... 还有 %d 个' % (len(bad) - 60))
    else:
        print('\n[OK] 所有共同符号的 CRC 完全一致 —— ABI 兼容，模块可以加载。')

    if missing:
        print('\n[WARN] %d 个 ROM 需要的符号我们的内核没导出（前 20 个）：' % len(missing))
        for s in missing[:20]:
            print('       %s' % s)

    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description='内核 ABI（模块符号 CRC）预检')
    sub = ap.add_subparsers(dest='cmd', required=True)

    b = sub.add_parser('baseline', help='从 .ko 目录生成 ABI 基线')
    b.add_argument('kodir')
    b.add_argument('-o', '--output')
    b.set_defaults(func=cmd_baseline)

    c = sub.add_parser('check', help='用 Module.symvers 核对 ABI')
    c.add_argument('symvers')
    c.add_argument('-b', '--baseline', required=True)
    c.set_defaults(func=cmd_check)

    v = sub.add_parser('dump-vmlinux',
                       help='从 vmlinux(ELF) 导出符号 CRC 表（只编 Image、没有 Module.symvers 时用）')
    v.add_argument('vmlinux')
    v.add_argument('-o', '--output', required=True)
    v.set_defaults(func=cmd_dump_vmlinux)

    args = ap.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
