# Türkçe yama desteği — tasarım

## Amaç
Kullanıcı Türkçe yamaları kendisi bulamıyor; nerede aranacağını da bilmiyor. Kadeh, kütüphanedeki bir Steam
oyunu için bilinen bir Türkçe yama varsa bunu göstermeli, kullanıcının onayıyla kurmalı ve kaldırabilmeli.
Başarı ölçütü: Spider-Man Remastered (App ID 1817070) Kadeh'ten kurulan yamayla Türkçe açılıyor, Kadeh'ten
kaldırılınca İngilizceye dönüyor.

## Hedefler
- Kütüphane kartında Steam oyunu için "Türkçe Yama…" menüsü; yama bilgisi, kur, kaldır.
- Yalnızca Kadeh'in kataloğunda doğrulanmış (sha256'sı bilinen) yamalar kurulabilir.
- Kurulum öncesi kaynak sayfası, dosya adı, boyut, sha256 ve çalıştırılacak exe kullanıcıya gösterilir; onaysız
  ve sessiz çalıştırma yok. Yükleyici görünür penceresiyle çalışır, kullanıcı kendisi ilerler.
- Kaldırma, yamanın kendi kaldırıcısına değil Kadeh'in kendi yedeğine dayanır.

## Hedef dışı
- Siteleri tarayıp yama otomatik bulmak, uzaktan güncellenen katalog, yama ikonları/rozetleri.
- Steam dışı (sabitlenmiş exe) oyunlar.
- Genel amaçlı "dosya farkı" motoru; kurulum sonrası düzeltmenin genel bir eklenti sistemi.

## Asla yapılmayacaklar
- Ücretli, üyelikli, Patreon kilitli ya da giriş/Discord isteyen yamayı indirmek veya kilidini atlatmak.
  Bunlar katalogda yalnızca bilgi + "Sayfayı aç" bağlantısı olarak durur.
- Sitelerin indirme kapısını (geri sayım, reklam, JS butonu) betikle aşmak. turkceyama.com'da indirme bir JS
  butonu, geri sayım ve reklam yükleyicisiyle geliyor ve doğrudan dosya bağlantısı yok; bu bilinçli bir kapı.
- sha256'sı eşleşmeyen dosyayı çalıştırmak.

## Kaynaklar (araştırmanın sonucu)
- **turkceyama.com**: en büyük ücretsiz ve girişsiz arşiv (sitemap'te 1166 yama sayfası). Spider-Man yaması buradan.
- **anonymousceviri.com**: üyelikli (199 TL'den) + kendi Windows istemcisi → yalnızca bağlantı.
- **apexyama.com**: DonanımHaber'de "Ücretli Yamalar" altında → yalnızca bağlantı.
- **oyundunyasi.net**: Calypso launcher + Discord kimliği/sunucusu şartı → katalogda yer almaz.
- Kataloğu olmayan oyunlar için sheet'te tek bir "turkceyama.com'da ara" bağlantısı (site araması, tarayıcıda).

## Katalog
`GameDBEntry`'ye isteğe bağlı `turkishPatches: [TurkishPatch]` alanı (GameDB.json içinde). Bir oyunun birden çok
kaynağı olabilir (ücretsiz + ücretli). Kütüphanedeki Steam kartı App ID taşıdığı için eşleştirme
`steamAppId` ile yapılır.

```json
"turkishPatches": [
  {
    "id": "turkceyama-calypso",
    "source": "turkceyama.com",
    "pageURL": "https://turkceyama.com/marvels-spider-man-remastered-turkce-yama",
    "translator": "Calypso (Emre Merev)",
    "kind": "Düzenlenmiş makine çevirisi",
    "access": "free",
    "file": {
      "name": "marvels-spider-man-remastered-turkce-yama_Kurulum.zip",
      "size": 14357728,
      "sha256": "a30611ad9acc9de1b6567f50378fb8cccbe66f5f1e56ea3e34bf1962386c09b3"
    },
    "installer": "Spiderman Remastered Türkçe Yama/Spiderman Remastered Türkçe Yama.exe",
    "modifiedFiles": ["asset_archive/toc"],
    "addedFiles": ["asset_archive/calypso.SMTR", "asset_archive/toc.yedek", "SpidermanRemastered_YamaKaldır.exe"],
    "fixup": "spiderManTocMerge"
  },
  { "id": "anonymous-ceviri", "source": "anonymousceviri.com", "pageURL": "…", "access": "paid", … }
]
```

`access` değerleri: `free` (kurulabilir) ve `paid` (yalnızca bağlantı). `file`/`installer` yalnızca `free`
için zorunlu; eksikse kayıt da yalnızca bağlantı olarak gösterilir.

## Akış
1. **Sheet açılır**: kütüphane kartı → sağ tık → "Türkçe Yama…". Oyunun katalog kayıtları listelenir: kaynak,
   çeviren, tür, ücretli/ücretsiz, durum (kurulu değil / kurulu / oyun güncellenmiş).
2. **İndirme**: "Sayfayı aç" kaynak sayfasını varsayılan tarayıcıda açar; kullanıcı dosyayı kendisi indirir.
3. **Dosyayı bulma**: "Kur…" basılınca Kadeh `~/Downloads` içinde boyutu tutan dosyaları sha256 ile dener
   (tarayıcı adın sonuna "(1)" ekleyebilir, bu yüzden ada değil boyut+hash'e bakılır). Bulamazsa dosya seçme
   penceresi açılır. Hash tutmazsa kurulum yapılmaz ve bu söylenir.
4. **Onay**: kaynak sayfası, dosya yolu, boyut, sha256 (doğrulandı), çalıştırılacak exe adı, yamanın
   değiştireceği/ekleyeceği dosyalar gösterilir. "Kur" basılmadan hiçbir şey çalışmaz.
5. **Kurulum**:
   - Arşiv `/usr/bin/bsdtar` ile bottle içinde geçici bir klasöre açılır (RAR5 dahil; Spider-Man dosyası `.zip`
     uzantılı bir RAR5). Yükleyici Wine'da sorun çıkarmasın diye ASCII bir ada kopyalanır.
   - `modifiedFiles` oyun klasöründeki `.kadeh-yama/<yama-id>/` altına yedeklenir.
   - Yükleyici `Wine.runProgram` ile görünür çalıştırılır; Kadeh bitmesini bekler.
   - `addedFiles` oluşmadıysa kurulum başarısız sayılır, yedek geri yüklenir.
   - `fixup` varsa çalıştırılır (aşağıda). Başarısız olursa yedek geri yüklenir, eklenen dosyalar silinir.
   - `.kadeh-yama/<yama-id>/state.json`: kurulum tarihi, dosya sha256'sı, kurulum sonrası `modifiedFiles` hash'leri.
   - Geçici klasör silinir.
6. **Durum**: state.json var ve `modifiedFiles` hash'leri tutuyorsa "kurulu". state.json var ama hash tutmuyorsa
   "Oyun güncellenmiş, yama bozulmuş olabilir" → yeniden kur önerilir.
7. **Kaldırma**: yedek geri yüklenir, `addedFiles` silinir, `.kadeh-yama/<yama-id>/` silinir. Durum "oyun
   güncellenmiş" ise yedek geri yüklenmez (eski sürümün toc'u oyunu bozar), yalnızca eklenen dosyalar silinir.
   Yamanın kendi `YamaKaldır.exe`'si çalıştırılmaz.

## Spider-Man toc düzeltmesi (`spiderManTocMerge`)
turkceyama'daki yükleyici Ekim 2023 tarihli. `asset_archive/toc`'u hazır ve eski bir toc ile değiştiriyor;
güncel oyun bununla siyah ekranda kalıyor (14.10.2026'da yaşandı). Çalışan çözüm, güncel toc'u temel alıp
yamalı toc'tan yalnızca yamanın eklediği yeni arşive (`calypso.SMTR`) yönlenen kayıtları almak:

- toc biçimi: 4 bayt sihir `AF 12 AF 77`, 4 bayt açılmış boyut (LE), ardından zlib akışı (başlıklı).
  Açılmış veri `DAT1`: 12. bayttan bölüm sayısı, 16. bayttan (etiket, ofset, boyut) üçlüleri.
- Bölümler: arşiv listesi `0x398abff0` (72 baytlık kayıtlar), kayıt ofsetleri `0xdcd720b5` (8 bayt/kayıt;
  ilk 4 bayt arşiv indeksi), boyutlar `0x65bcf461` (12 bayt/kayıt), kimlikler `0x506d7b8a`.
- Kurallar (eski Python betiğinin assert'leri aynen korunur; biri tutmazsa düzeltme durur ve yedek geri yüklenir):
  arşiv listesi dışındaki bölümler iki toc'ta birebir aynı; yamalı arşiv listesi orijinalle başlıyor.
  Yamalı toc'ta arşiv indeksi ≥ orijinal arşiv sayısı olan kayıtlar yamalıdan, kalanlar orijinalden alınır.
- Çıktı: sihir + yeni boyut + zlib. Apple `Compression` çerçevesinin ZLIB'i ham deflate'tir; 2 baytlık zlib
  başlığı ve adler32 elle eklenir/atlanır.
- "Orijinal" toc = Kadeh'in kurulum öncesi aldığı yedek; "yamalı" toc = yükleyicinin yazdığı.
- Referans: 14.10.2026'da elle çalıştırılıp oyunu Türkçe açtıran betik (Swift'e bu davranışla taşınır).
  Değişken adlarına dikkat: `OFFS` (0xdcd720b5) aslında (arşiv indeksi, ofset) çiftleri, `SIZES` (0x65bcf461) 12 baytlık kayıtlar.
  Gerçek sonuç: 771677 kayıttan yalnızca 1'i yamadan alındı (arşiv 46, ofset 0).

```python
# Spider-Man Remastered toc birlestirici: guncel toc + yamadaki yalnizca yeni arsive (calypso) yonlenen kayitlar.
import sys, zlib, struct
ARCH, SIZES, OFFS, IDS = 0x398abff0, 0x65bcf461, 0xdcd720b5, 0x506d7b8a

def load(p):
    d = open(p, 'rb').read()
    assert d[:4] == b'\xaf\x12\xaf\x77'
    return bytearray(zlib.decompressobj().decompress(d[8:]))

def secs(buf):
    return {t: (o, s) for t, o, s in (struct.unpack_from('<III', buf, 16 + 12 * i) for i in range(struct.unpack_from('<I', buf, 12)[0]))}

orig, yama = load(sys.argv[1]), load(sys.argv[2])
so, sy = secs(orig), secs(yama)
for t in so:
    if t not in (ARCH, SIZES, OFFS):
        assert orig[so[t][0]:so[t][0]+so[t][1]] == yama[sy[t][0]:sy[t][0]+sy[t][1]], hex(t)
    if t != ARCH:
        assert so[t] == sy[t], hex(t)
oa, ya = orig[so[ARCH][0]:so[ARCH][0]+so[ARCH][1]], yama[sy[ARCH][0]:sy[ARCH][0]+sy[ARCH][1]]
assert ya[:len(oa)] == oa
new_idx = len(oa) // 72  # yamanin ekledigi arsiv(ler) bu indeksten baslar

out = bytearray(yama)
n = so[IDS][1] // 8
oo, ss = so[OFFS][0], so[SIZES][0]
kept = 0
for i in range(n):
    if struct.unpack_from('<I', yama, oo + i * 8)[0] >= new_idx:
        kept += 1
        continue
    out[oo + i * 8: oo + i * 8 + 8] = orig[oo + i * 8: oo + i * 8 + 8]
    out[ss + i * 12: ss + i * 12 + 12] = orig[ss + i * 12: ss + i * 12 + 12]
open(sys.argv[3], 'wb').write(b'\xaf\x12\xaf\x77' + struct.pack('<I', len(out)) + zlib.compress(bytes(out), 9))
print('yamadan alinan kayit:', kept, '/ toplam', n)
```

## Yükleyici hakkında bilinenler
- .NET Framework 4.7.2 WinForms uygulaması (Costura ile paketli). `toc`, `calypso.SMTR` ve `YamaKaldır.exe`
  gömülü kaynak olarak içinde. Bottle'da Wine Mono 11.3 kurulu; çalışması beklenir, uçtan uca testte doğrulanır.
- Oyun klasörünü kendisi bulmuyor; kullanıcıya klasör seçtiriyor (`IsFolderPicker`). Bu yüzden onay ekranı
  seçilecek Windows yolunu (ör. `C:\Program Files (x86)\Steam\steamapps\common\Marvel's Spider-Man Remastered`)
  kopyalanabilir biçimde gösterir. Yanlış klasör seçilirse `addedFiles` denetimi bunu yakalar ve kurulum geri alınır.
- `toc.yedek` yükleyicinin kendi yedeği; `addedFiles` içinde, Kadeh kaldırırken siler. Kadeh'in yedeği ayrı
  (`.kadeh-yama/`). Oyun klasöründeki `toc.yama` yükleyiciden değil, 14.10.2026'daki elle kurulumdan kalma;
  yalnızca uçtan uca testten önceki temizlikte silinir.

## Kapsam kararları (kurucunun çağrısı değil, tasarımın)
- İlk sürümde tek kurulabilir kayıt: Spider-Man Remastered (turkceyama). Aynı oyunun ücretli kaynakları
  (Anonymous Çeviri, Apex) bağlantı olarak eklenir. Yeni oyunlar, GameDB kayıtları gibi tek tek doğrulanarak eklenir.
- `fixup` kapalı bir enum; şimdilik tek değeri `spiderManTocMerge`.
- "Oyun güncellenmiş" durumunda yedek geri yüklenmez: toc'u Steam yeniden yazdığı için artık `calypso.SMTR`'ye
  yönlenmiyor, eklenen dosyaları silmek güvenli. Sheet yine de "Steam'de dosya bütünlüğünü doğrula" önerisini gösterir.

## Test
- `swift test`: katalog alanının çözülmesi; sentetik küçük bir toc ile birleştirme (yeni arşive yönlenen kayıt
  alınır, diğerleri korunur, assert ihlalinde hata); durum hesabı (kurulu / güncellenmiş).
- Uçtan uca (Spider-Man, "Steam" bottle'ı): oyun şu an elle yamalı. Önce elle temizlenir (`toc.yedek` → `toc`;
  `calypso.SMTR`, `toc.yama`, `YamaKaldır.exe` silinir) → Kadeh'le kurulur → oyun açılır, Türkçe doğrulanır →
  Kadeh'le kaldırılır → İngilizce doğrulanır → kullanıcı Türkçe kalsın diye Kadeh'le yeniden kurulur.

## Kurucuya bırakılanlar
Sheet'in yerleşimi ve metinleri (Türkçe, yazım kontrollü), kod dosyalarının bölünmesi, Library'den kurulum
klasörüne ulaşma (`SteamLibrary.enumerate` ile App ID'den `installURL`).
