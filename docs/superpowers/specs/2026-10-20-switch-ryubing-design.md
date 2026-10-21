# Nintendo Switch oyunları (Ryubing) — tasarım

> **Güncelleme (2026-10-20, kullanıcı kararı):** Ryubing'in sunucusu (git/update.ryujinx.app) gün boyu her yerden
> erişilemediği için emülatör **Eden** oldu ("Ryubing geri gelirse sonra eklenir"). Tasarımın geri kalanı aynı;
> değişenler:
> - Kaynak: git.eden-emu.dev kararlı sürümü v0.2.1, `https://stable.eden-emu.dev/v0.2.1/Eden-macOS-v0.2.1.dmg`,
>   SHA-256 `40575fc7…c0b5` kodda sabit. Eden de checksum/imza yayımlamıyor; sabitlemeden önce dosya, aynı sürüme
>   ekli `.torrent`'in parça karmalarıyla da karşılaştırıldı (22/22 parça, dosyanın %95'i). Uygulama ad hoc imzalı.
> - Kurulum: DMG salt okunur bağlanır, `eden.app` `ditto` ile `Switch/` altına kopyalanır, karantina silinir.
> - Taşınabilir kip: Eden macOS'ta `.app`'in bulunduğu klasöre geçer ve oradaki `user/` klasörünü kullanır.
>   Anahtar `user/keys/prod.keys`, firmware `user/nand/system/Contents/registered/` (Eden `<id>.nca/00` düzenini de
>   okur). Gerçek kurulum ve bir oyunsuz açılışla doğrulandı: ev dizininde Eden klasörü oluşmadı.
> - Başlatma: `eden -f -g <oyun>`. Eden macOS'ta SIGTERM'i yok sayıyor; "Durdur" önce uygulamanın normal Çık
>   isteğini gönderir (2 sn'de kapandı), 10 sn sonra SIGKILL.
> - Eden'in kendi güncelleme denetimi, ayar dosyası varsa her başlatmada kapatılır.
> - Eden'in macOS sürümü kendi notlarına göre deneysel; arayüz bunu bir cümleyle söyler.

## Amaç
Kullanıcı her oyunu tek uygulamadan oynamak istiyor. İstediği bir Switch oyunu Steam'de yok. Kadeh, kullanıcının
kendi konsolundan aldığı .nsp/.xci oyunlarını Windows oyunlarıyla aynı kütüphanede göstermeli ve aynı "Oyna"
düğmesiyle Ryubing emülatöründe açmalı.
Başarı ölçütü: kullanıcı bir oyun klasörü seçiyor, oyun kütüphanede beliriyor, "Oyna" Ryubing'i tam ekran açıyor;
oyun kapanınca kart "çalışıyor" durumundan çıkıyor ve süre sayılıyor.

## Hedefler
- Ryubing, Wine motoru gibi isteğe bağlı bir Kadeh bileşeni olarak indirilip kurulur (uygulamaya gömülmez).
- Anahtar (prod.keys) ve sistem yazılımı (firmware) yalnızca kullanıcının kendi dosyalarından içe aktarılır.
- Eksik bir şey varsa oyun açılmadan önce düz Türkçe bir ileti ve tek bir "çöz" düğmesi gösterilir.
- Teknolojiyle arası zayıf bir kullanıcı her şeyi tek bir yerden, en az tıklamayla kurar.

## Hedef dışı (v1)
- Güncelleme ve DLC kurulumu (Ryubing'in kendi penceresinden yapılır), kayıt yedekleme, çok oyunculu (LDN),
  oyun başına grafik ayarı, Ryubing'in kendi ayarlarını Kadeh'ten yönetmek.
- XCI içinden firmware kurmak (HFS0 + şifre çözme gerektirir).
- Intel Mac (Ryubing yalnızca Apple Silicon'u düzgün destekliyor).

## Asla yapılmayacaklar
- prod.keys, title.keys, firmware ya da oyun indirmek; bunların nerede bulunacağını söylemek veya bağlantı vermek.
- Ryubing'i resmî kaynağı dışından (ayna, üçüncü taraf) indirmek.

## Ryubing hakkında bilinenler (araştırma)
- Lisans MIT. Resmî site ryujinx.app; sürümler git.ryujinx.app (Forgejo) üzerinde. GitHub'da sürüm yok.
- Güncelleme API'si: `https://update.ryujinx.app/latest/query?os=mac&arch=arm64&rc=stable` →
  JSON `{ "tag", "download_url", "max_concurrency", "web_url_format" }`. Kaynak: github.com/Ryubing/UpdateServer
  (`LatestController`, `VersionResponse`). macOS dosyası `ryujinx-<sürüm>-macos_universal.app.tar.gz`.
- Bütünlük: Ryubing ne checksum ne imza yayımlıyor; macOS paketi ad hoc imzalı, noter onaysız. Kendi güncelleyicisi
  de karma denetimi yapmıyor, yalnızca karantina özniteliğini siliyor.
- **2026-10-20 itibarıyla git.ryujinx.app ve update.ryujinx.app (91.239.78.255) her yerden erişilemiyor**
  (bu Mac ve Brezilya/İngiltere/Türkiye/Endonezya'daki dış noktalar: zaman aşımı). Sürüm etiketi, indirme adresi ve
  SHA-256 sunucu dönünce alınacak.
- Komut satırı: `Ryujinx.app/Contents/MacOS/Ryujinx [--fullscreen] [--hide-updates] <oyun yolu>`.
- Taşınabilir kip: `.app` paketinin yanında `portable` klasörü varsa tüm veri oraya yazılır. Anahtarlar
  `portable/system/prod.keys`, firmware `portable/bis/system/Contents/registered/<ncaid>.nca/00`.
- prod.keys yoksa Ryubing İngilizce bir hata penceresi açıyor; firmware yoksa oyunu başlatmıyor.
- Oyun durdurulunca Ryubing kapanmıyor, kendi oyun listesine dönüyor. Pencere kapatılınca süreç bitiyor.
- Ryubing'in firmware kurulumu şifre çözmüyor: klasör ya da .zip içindeki her `<id>.nca` / `<id>.cnmt.nca`
  dosyasını `registered/<id>.nca/00` olarak kopyalıyor (`ContentManager.InstallFromZip/InstallFromDirectory`).

## Tasarım

### Klasör düzeni
`~/Library/Application Support/com.furkan.kadeh/Switch/` (Symantec istisnasının içinde; `Libraries/` altında değil,
çünkü motor kurulumu `Libraries/`'i silip yeniden yazıyor):
- `Ryujinx.app` — Ryubing.
- `portable/` — Ryubing'in tüm verisi (anahtarlar, firmware, kayıtlar, ayarlar). Kadeh kurulumda boş olarak açar.
- `version` — kurulu Ryubing sürümü (düz metin).

### Ryubing kurulumu
- İndirme mevcut `ResumableDownloader` ile, yalnızca `https://git.ryujinx.app/` ile başlayan adresten.
- Doğrulama (kullanıcı kararı, 2026-10-20): Kadeh belirli bir Ryubing sürümünü, indirme adresini ve SHA-256'sını
  kodda sabitler; karma uyuşmazsa dosya silinir, kurulum yapılmaz. Yeni Ryubing için sabit güncellenir. Sabit,
  sunucu dönünce ilk indirmeden doldurulur; o zamana kadar kurulum "Ryubing sunucusuna şu an ulaşılamıyor" der.
- Açma: `Tar.untar` (gzip; `.tar.xz` değil `.tar.gz` dosyası). Ardından `com.apple.quarantine` özyinelemeli silinir
  ve `Contents/MacOS/Ryujinx` çalıştırılabilir mi diye bakılır. Önce geçici klasöre açılır, başarılıysa eskisinin
  yerine taşınır; `portable/` hiç silinmez.
- Kadeh'in imzası Ryubing'e dokunmaz; Ryubing kendi ad hoc imzasıyla çalışır.

### Anahtar ve firmware içe aktarma
- Anahtar: kullanıcı `prod.keys` dosyasını seçer. Kadeh içinde `header_key = <64 onaltılık>` satırı olup olmadığına
  bakar, `portable/system/prod.keys` olarak kopyalar; aynı klasörde `title.keys` varsa onu da kopyalar.
- Firmware: kullanıcı bir klasör ya da .zip seçer. .zip `ditto -x -k` ile geçici klasöre açılır. İçinde en az bir
  `.cnmt.nca` ve toplam 50'den fazla `.nca` yoksa "Bu bir sistem yazılımı klasörü gibi görünmüyor" denir.
  Dosyalar Ryubing'in yaptığı gibi `registered.tmp/<id>.nca/00` düzenine kopyalanır, sonra `registered` ile
  değiştirilir.
- Kadeh bu dosyaları hiçbir yerden indirmez ve nerede bulunacağını söylemez. İletiler "kendi konsolundan aldığın"
  ifadesini kullanır.

### Kütüphane
- Ayar: tek bir "Switch oyunları klasörü" (UserDefaults'ta düz yol; uygulama sandbox'ta değil).
- `SwitchLibrarySource`: klasör ve alt klasörlerdeki `.nsp` / `.xci` dosyaları. Adı `[UPD]`, `[DLC]` içeren ya da
  köşeli parantezdeki 16 haneli başlık kimliği `000` ile bitmeyen dosyalar (güncelleme/DLC) gösterilmez.
- Ad (v1): dosya adından; uzantı, `[…]` ve `(…)` parçaları atılır, `_` boşluğa çevrilir.
- Kapak (v1): oyunun kendi kapağı yok; Switch'e özgü bir yer tutucu (kırmızı degrade + oyun adı).
  Gerçek ad ve ikon sonraki aşamada.
- Kart üzerinde konum etiketi "Nintendo Switch" olur (şişe adının durduğu yer), kullanıcı hangi oyunun Switch
  olduğunu görür.
- `LibraryEntry.bottleURL` tipi değişmez; anlamı "girdinin çalıştığı klasör" olur: Wine şişesi ya da Switch oyunu
  için emülatörün `portable/` klasörü. Böylece şişe aramaları Switch girdisinde kendiliğinden boş döner (35 kullanım
  yerine dokunmadan). Şişeye bağlı menüler (Yapılandır, Türkçe yama, sabitlemeyi kaldır, kayıt yedekleme bölümü)
  Switch girdisinde gizlenir.
- `LibraryEntry.Launch`'a `.switchGame(URL)` eklenir. Bilinen etki alanı: `LibraryModel` (state, launch, run log),
  `GraphicsProbe`, `GameArtwork` (InstallSize), `GameProcesses`, `GameSavesSection`, `GameEndActions`,
  `LibraryView`, `GamePageView`, `PlaytimeView` içindeki `switch` ve `if case` kullanımları.
- Kütüphane yeniden yükleme tetikleyicisine (`libraryReloadTrigger`) Switch klasörü ve Ryubing kurulu mu bilgisi
  eklenir.

### Oyna
1. Ön denetim: Ryubing kurulu mu, `portable/system/prod.keys` var mı, `registered/` boş değil mi, oyun dosyası
   duruyor mu. Eksik olan ilk adım için Türkçe ileti + o adımı çözen düğme (kurulum sayfasını o adımda açar).
2. `Process` ile `Ryujinx --fullscreen --hide-updates <oyun>` başlatılır; Kadeh süreç tanıtıcısını tutar.
3. `GameSessions` yeni bir yol alır: `began(_ entry:, process:)`. Oturum hemen "çalışıyor" sayılır, süreç bitince
   mevcut `finish` ile kapanır; böylece oynama geçmişi ve süre mevcut `ended` hattından yazılır.
   `GameEndActions` süreyi `.switchGame` için de kaydeder.
4. "Durdur": Ryubing sürecine SIGTERM, 10 sn sonra hâlâ yaşıyorsa SIGKILL (`GameCloser`'a Wine'sız dal).
5. Bilinen sınır: kullanıcı oyunu Ryubing menüsünden durdurursa Ryubing kendi listesine döner ve Kadeh, Ryubing
   penceresi kapanana kadar oyunu çalışıyor gösterir.

### Arayüz — tek kurulum sayfası
- "Switch oyunları" sayfası (sheet), dört adımlı bir kontrol listesi; her adımda durum (✓ / eksik) ve tek düğme:
  1. Emülatörü indir (ilerleme çubuğu),
  2. Anahtar dosyanı seç (prod.keys),
  3. Sistem yazılımını seç (klasör ya da .zip),
  4. Oyun klasörünü seç.
- Açıldığı yerler: kütüphane araç çubuğundaki "Switch oyunu ekle" düğmesi, boş kütüphane ekranı, Ayarlar'daki
  "Nintendo Switch" satırı ve Oyna ön denetimindeki "çöz" düğmesi. Ayrı bir ayar formu yok; Ayarlar'da yalnızca
  durum özeti ve bu sayfayı açan düğme var.
- Tüm metinler `Localizable.xcstrings` içinde İngilizce anahtar + `en` ve `tr` değerleriyle. Türkçe metinler TDK
  yazımıyla denetlenir; "NSP", "NCA" gibi kısaltmalar arayüzde geçmez ("oyun dosyası", "sistem yazılımı").

## Test
- Yapılabilecek: Ryubing kurulumu (sunucu dönünce), anahtar ve firmware içe aktarmanın klasör düzeni (sahte
  dosyalarla), ön denetim iletileri, dosya adı ayrıştırma ve güncelleme/DLC elemesi için tek bir küçük test,
  imzalı derleme.
- Kullanıcı onayıyla: Ryubing'i bir kez oyunsuz açıp kapatmak (GUI açtığı için).
- Yalnız kullanıcının yapabileceği: gerçek prod.keys, firmware ve kendi oyun dökümüyle Oyna akışı.

## Kullanıcı kararları (2026-10-20)
1. Ryubing doğrulaması: sürüm + SHA-256 kodda sabit.
2. Ad ve kapak: v1 dosya adı + yer tutucu. Oyunun içinden gerçek ad ve ikon okuyucusu sonraki aşama; gerçek bir
   dökümle test edilerek eklenir.
3. Tasarım onaylandı; test için Ryubing'in bir kez oyunsuz açılıp kapatılmasına izin verildi.

## Kurucuya bırakılanlar
- Yer tutucu kapağın görünümü, ilerleme ve hata metinlerinin tam sözcükleri (TDK denetimiyle), kod yerleşimi.

## Tasarımcının kararları (inceleme sonrası)
- Taşınabilir kip ve yollar Ryubing kaynağından doğrulandı (`AppDataManager.Initialize`: `.app`'in yanındaki
  `portable`; `KeysDir = "system"`; `SystemNandPath = bis/system`, `ContentPath.Contents`). Sunucu dönünce ilk
  kurulumda yine elle bakılır.
- Ryubing macOS'ta tek süreçtir (.NET); Kadeh başlattığı PID'yi izler. Kadeh kapanıp açılırsa çalışan Ryubing'i
  sahiplenmez (v1); oturum o an kaybolur.
- Ön denetim yalnızca varlık denetimidir; anahtar/firmware uyumunu Ryubing'in kendisi denetler. Firmware önce
  `registered.tmp`'ye yazılır; yalnızca kopyalama başarılıysa eski `registered` silinip yerine konur.
- Firmware klasörü özyinelemeli taranır; eşik (en az bir `.cnmt.nca`, 50'den fazla `.nca`) tek bir sabittir.
- Güncelleme/DLC elemesi: temel oyun kimlikleri hep `000` ile biter (güncelleme `800`, DLC başka). Köşeli parantezde
  kimlik yoksa dosya gösterilir.
- Girdi kimliği `switch:` + dosya yolu (programlar gibi yola bağlı); dosya taşınırsa süre geçmişi yeni girdiye geçmez.
- Kurulum kodu `UpdateServer` kaynağındaki JSON biçimine (`tag`, `download_url`) göre yazılır; sunucu dönene kadar
  uçtan uca denenemez.
- Kadeh sandbox'ta değil; ad hoc imzalı bir ikiliyi `Process` ile çalıştırmak Kadeh'in imzasından etkilenmez,
  karantina özniteliği silindikten sonra Gatekeeper engellemez.
