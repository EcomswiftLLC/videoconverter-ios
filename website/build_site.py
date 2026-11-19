"""Builds the static Fluxa site into website/fluxa/ (published at https://ecomswiftllc.github.io/fluxa/).

  python website/make_site_assets.py   (icon, favicons, og image; needs tools/make_icon.py output)
  python website/build_site.py
  (optional) FLUXA_SUPPORT_EMAIL=<public support address>   overrides the address read from docs/legal
  (optional) FLUXA_SITE_OUT=<folder>                         write the pages somewhere else (review builds)

Writes index.html, formats/, support/, privacy/, terms/, licenses/ (each index.html), sitemap.xml, robots.txt.
Privacy and terms come from docs/legal/*.md (the DRAFT-NOTICE block is stripped). The format tables mirror
Sources/Model/Formats.swift (OutputFormat, InputFormats.groups) and VideoApps-Spec/SPEC.md: when the app's format list
changes, change FORMATS_OUT / FORMATS_IN here too. If website/fluxa/assets/shots/*.jpg exist the home page shows them.
Publishing: copy website/fluxa/ into the fluxa/ folder of the EcomswiftLLC/ecomswiftllc.github.io repository (Pages
serves its main branch), see docs/store/metadata.md.
"""
import html
import json
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_SITE = ROOT / "website" / "fluxa"
OUT = Path(os.environ.get("FLUXA_SITE_OUT") or SRC_SITE)
LEGAL = ROOT / "docs" / "legal"

BASE = "https://ecomswiftllc.github.io/fluxa/"
UPDATED = "2026-11-19"
SITE_NAME = "Video Converter MP4 MKV: Fluxa"


def read_support_email():
    env = os.environ.get("FLUXA_SUPPORT_EMAIL", "").strip()
    if env:
        return env
    text = (LEGAL / "privacy-policy.md").read_text(encoding="utf-8")
    m = re.search(r"\*\*Contact:\*\*\s*(\S+@\S+)", text)
    if not m:
        sys.exit("No support address: set FLUXA_SUPPORT_EMAIL or keep the Contact line in docs/legal/privacy-policy.md.")
    return m.group(1).strip()


SUPPORT_EMAIL = read_support_email()
EMAIL_TEXT = f'<span class="email">{html.escape(SUPPORT_EMAIL)}</span>'

# ----------------------------------------------------------------------------- format data (mirrors Formats.swift)
# (format, best for, video codecs, audio codecs)
FORMATS_OUT = {
    "Video": [
        ("MP4", "Plays almost everywhere. The safe choice.", "H.264, HEVC, MPEG-4, VP9", "AAC, MP3, AC-3, Apple Lossless"),
        ("MOV", "Apple's format. Best for editing on a Mac.", "H.264, HEVC, ProRes 422, Motion JPEG, MPEG-4", "AAC, Apple Lossless, PCM, MP3"),
        ("M4V", "MP4 for Apple TV and Apple's media apps.", "H.264, HEVC, MPEG-4, VP9", "AAC, MP3, AC-3, Apple Lossless"),
        ("3GP", "Tiny files for old phones and MMS.", "H.264, MPEG-4, H.263", "AAC, AMR"),
        ("MKV", "Holds any codec, many audio tracks and subtitles.", "H.264, HEVC, VP9, VP8, MPEG-4, Theora", "AAC, Opus, Vorbis, MP3, FLAC, AC-3, PCM"),
        ("WebM", "Open web video for browsers and Android.", "VP9, VP8", "Opus, Vorbis"),
        ("AVI", "Classic Windows video, old players.", "MPEG-4, H.264, Motion JPEG, WMV 8", "MP3, AAC, AC-3, PCM"),
        ("FLV", "Flash video for legacy sites and tools.", "H.264, Sorenson H.263", "AAC, MP3"),
        ("WMV", "Windows Media for older PCs and Office.", "WMV 8, MPEG-4", "WMA"),
        ("MPG", "MPEG-2 for DVD players and old TVs.", "MPEG-2, MPEG-4", "AC-3, MP3"),
        ("MPEG-TS", "Broadcast streams, AVCHD and IPTV.", "H.264, HEVC, MPEG-2", "AAC, AC-3, MP3"),
        ("OGV", "Open Theora video for Linux players.", "Theora", "Vorbis, Opus"),
    ],
    "Audio": [
        ("M4A", "AAC audio. Great quality in small files.", "", "AAC, Apple Lossless"),
        ("MP3", "Plays on every device ever made.", "", "MP3"),
        ("WAV", "Uncompressed audio for editing.", "", "PCM"),
        ("AIFF", "Apple's uncompressed audio.", "", "PCM"),
        ("CAF", "Core Audio, for GarageBand and Logic.", "", "PCM"),
        ("FLAC", "Lossless audio at about half the size of WAV.", "", "FLAC"),
        ("OGG", "Open Vorbis audio, popular in games.", "", "Vorbis, Opus"),
        ("Opus", "The most efficient voice and music codec.", "", "Opus"),
        ("AC3", "Dolby Digital for home theatre.", "", "AC-3"),
    ],
    "Animated image": [
        ("GIF", "Silent looping clip that works in any chat.", "Palette-optimised frames", "None"),
        ("WebP", "Animated WebP, smaller than GIF.", "WebP frames", "None"),
        ("APNG", "Animated PNG with full colour.", "PNG frames", "None"),
    ],
}

FORMATS_IN = [
    ("Apple video", "MP4, MOV, M4V, 3GP, 3G2, QT, HEVC and HEIC video, ProRes, Live Photo video, slow motion and Cinematic clips"),
    ("Open and web video", "MKV, WebM, OGV, OGG and OGM video, AV1, VP8 and VP9, GIF, animated WebP, APNG"),
    ("Windows and legacy video", "AVI (including DivX and XviD), WMV, ASF, FLV, F4V, RM, RMVB"),
    ("Camera, DVD and broadcast", "MPG, MPEG, MPE, M2V, VOB, TS, M2TS, MTS (AVCHD), MXF, DV, MJPEG"),
    ("Audio", "MP3, AAC, M4A, WAV, AIFF, CAF, FLAC, OGG, OGA, Opus, WMA, AMR, AC3, EAC3, MKA"),
]

TOKENS_IN = ["MKV", "AVI", "WebM", "WMV", "FLV", "MOV", "MP4", "MTS", "VOB", "MPG", "3GP", "OGV", "RMVB", "MXF"]
TOKENS_OUT = ["MP4", "MOV", "MKV", "WebM", "AVI", "WMV", "MPG", "MP3", "M4A", "WAV", "FLAC", "GIF"]

PRESETS = [
    ("Universal MP4", "H.264 and AAC, plays on nearly anything"),
    ("iPhone and iPad", "Made for Apple devices and Photos"),
    ("Android", "MP4 that Android phones open"),
    ("Web", "WebM with VP9 for browsers"),
    ("Windows", "WMV or AVI for older PCs"),
    ("Old TV or DVD player", "MPG or AVI for older players"),
    ("Editing", "ProRes in MOV for editing apps"),
    ("GIF", "A silent loop for chats"),
    ("Audio only", "The sound as MP3, M4A or WAV"),
    ("Fix won't play", "Re-made as H.264 and AAC in MP4"),
]


# ----------------------------------------------------------------------------- shell
def head(title, description, path, extra_head="", root=""):
    canonical = BASE + path
    t = html.escape(title)
    d = html.escape(description)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{t}</title>
<meta name="description" content="{d}">
<link rel="canonical" href="{canonical}">
<meta name="theme-color" content="#080B12">
<meta name="color-scheme" content="dark">
<link rel="icon" href="{root}assets/favicon.svg" type="image/svg+xml">
<link rel="icon" href="{root}assets/favicon-32.png" type="image/png" sizes="32x32">
<link rel="apple-touch-icon" href="{root}assets/apple-touch-icon.png">
<meta property="og:type" content="website">
<meta property="og:site_name" content="{html.escape(SITE_NAME)}">
<meta property="og:title" content="{t}">
<meta property="og:description" content="{d}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{BASE}assets/og-image.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="The Fluxa app icon, two aurora ribbons in a loop around a play button, next to the name Video Converter MP4 MKV: Fluxa">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{t}">
<meta name="twitter:description" content="{d}">
<meta name="twitter:image" content="{BASE}assets/og-image.png">
<link rel="stylesheet" href="{root}assets/site.css">
{extra_head}</head>
<body>
<a class="skip" href="#main">Skip to content</a>
"""


def header(root, current=""):
    def a(href, text, key):
        cur = ' aria-current="page"' if key == current else ""
        return f'<a href="{href}"{cur}>{text}</a>'
    home = root or "./"
    return f"""<header class="site-header">
  <div class="wrap">
    <a class="brand" href="{home}"><img src="{root}assets/fluxa-mark.svg" alt="" width="36" height="36">Fluxa</a>
    <nav class="nav" aria-label="Main">
      {a(root + 'formats/', 'Formats', 'formats')}
      {a(home + '#private', 'Privacy', 'p')}
      {a(home + '#free', 'Free with ads', 'f')}
      {a(home + '#faq', 'FAQ', 'q')}
      {a(root + 'support/', 'Support', 'support')}
    </nav>
  </div>
</header>
"""


def footer(root):
    home = root or "./"
    return f"""<footer class="site-footer">
  <div class="wrap">
    <div>
      <h2>Video Converter MP4 MKV: Fluxa</h2>
      <p>A free video and audio converter for iPhone and iPad. Your files are converted on your device. Not on the App Store yet.</p>
    </div>
    <nav aria-label="Footer">
      <h2>Pages</h2>
      <ul>
        <li><a href="{home}">Home</a></li>
        <li><a href="{root}formats/">Supported formats</a></li>
        <li><a href="{root}support/">Support</a></li>
        <li><a href="{root}privacy/">Privacy policy</a></li>
        <li><a href="{root}terms/">Terms of use</a></li>
        <li><a href="{root}licenses/">Open-source licences</a></li>
      </ul>
    </nav>
    <div>
      <h2>Ecom Swift LLC</h2>
      <p>30 N Gould St #37906<br>Sheridan, WY 82801<br>United States</p>
      <p class="email">{html.escape(SUPPORT_EMAIL)}</p>
    </div>
    <p class="legalline">&copy; 2026 Ecom Swift LLC. Apple, iPhone, iPad and the App Store are trademarks of Apple Inc. FFmpeg is a trademark of Fabrice Bellard. Fluxa is not affiliated with Apple, Google or the FFmpeg project.</p>
  </div>
</footer>
</body>
</html>
"""


# ----------------------------------------------------------------------------- home
FAQ = [
    ("Is Fluxa really free?",
     "<p>Yes. There is no subscription, no in-app purchase, no paid version and no watermark. Ads from Google AdMob pay for the app: a banner on the Home screen, and one rewarded video that you choose to watch before you save or share.</p>"),
    ("Are my videos uploaded anywhere?",
     "<p>No. Fluxa converts every file on your iPhone or iPad. We never receive your videos, your audio or your file names.</p>"),
    ("Why is MKV to MP4 so fast sometimes?",
     "<p>Many MKV files already hold H.264 or HEVC video and AAC audio, which MP4 can hold too. Then Fluxa only moves the streams into the new container instead of re-encoding them. It takes seconds and the picture and sound are exactly the same.</p>"),
    ("Which formats can it open and save?",
     "<p>It opens MKV, AVI, WebM, WMV, FLV, MOV, MP4, MTS, VOB and many more, and saves 12 video formats, 9 audio formats and 3 animated image formats. The <a href=\"formats/\">formats page</a> has the full list with codecs.</p>"),
    ("Why can't it convert a film I bought?",
     "<p>Films and shows bought or rented from a store, or downloaded from a streaming service, are protected by DRM. Fluxa cannot read protected or encrypted files, and it tells you so instead of failing quietly.</p>"),
    ("Why am I asked to watch an ad?",
     "<p>When you save or share, the app offers one short video that you choose to watch. One watched ad covers that export, even a whole batch, and further exports for 2 minutes. If you choose Not now, nothing is saved and you can try again any time. If no ad is available, for example when you are offline, the export goes ahead anyway. Choosing formats and converting never needs an ad.</p>"),
    ("Do I need an account?", "<p>No. There is no sign-in and no sign-up.</p>"),
    ("Does it need access to my photo library?",
     "<p>Not to open files. You pick videos with the iOS photo picker, and Fluxa sees only the ones you choose. To save a result, the app asks for add-only permission, which lets it add items and does not let it read your library. Files from the Files app need no permission.</p>"),
    ("What happens if I do not allow tracking?",
     "<p>The app works the same and the ads are less personalised. You can change the choice any time in iOS Settings under Privacy and Security, then Tracking. Fluxa runs no analytics of its own.</p>"),
    ("Which devices does it run on?",
     "<p>iPhone and iPad with iOS 17 or iPadOS 17 or later, in portrait and landscape. Saving as HEVC uses the hardware encoder, which some older devices do not have; Fluxa then offers H.264.</p>"),
    ("When can I download it?",
     "<p>Fluxa is not on the App Store yet, so there is no download link. This page will link to the App Store listing once the app is available.</p>"),
    ("Who makes Fluxa?",
     "<p>Ecom Swift LLC, a company registered in Wyoming, United States. You can reach us on the <a href=\"support/\">support page</a>.</p>"),
]


def jsonld_app():
    data = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": SITE_NAME,
        "alternateName": "Fluxa",
        "url": BASE,
        "applicationCategory": "MultimediaApplication",
        "operatingSystem": "iOS 17.0 or later",
        "description": "A free video and audio converter for iPhone and iPad. Convert MKV, AVI, WebM, WMV, FLV, MOV and more to MP4, MOV, MKV, WebM, AVI, MP3, GIF and other formats. Everything is converted on the device. Supported by ads.",
        "image": BASE + "assets/icon-512.png",
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "publisher": {"@type": "Organization", "name": "Ecom Swift LLC", "url": "https://www.ecomswiftllc.com/",
                      "address": {"@type": "PostalAddress", "streetAddress": "30 N Gould St #37906",
                                  "addressLocality": "Sheridan", "addressRegion": "WY", "postalCode": "82801",
                                  "addressCountry": "US"}},
        "featureList": [
            "Convert between 12 video, 9 audio and 3 animated image formats",
            "Lossless re-wrap when the codecs already fit",
            "Presets for iPhone, Android, web, Windows, DVD players and editing",
            "Extract audio as MP3, M4A, WAV, FLAC and more",
            "GIF, animated WebP and APNG from a clip",
            "Batch queue",
            "Converted on the device, no account",
        ],
    }
    return '<script type="application/ld+json">\n' + json.dumps(data, indent=2) + "\n</script>\n"


def jsonld_faq(items):
    plain = lambda s: html.unescape(re.sub(r"<[^>]+>", "", s))
    data = {"@context": "https://schema.org", "@type": "FAQPage",
            "mainEntity": [{"@type": "Question", "name": q,
                            "acceptedAnswer": {"@type": "Answer", "text": plain(a)}} for q, a in items]}
    return '<script type="application/ld+json">\n' + json.dumps(data, indent=2) + "\n</script>\n"


def specimen_html(root=""):
    roll = ["mkv", "avi", "webm", "wmv", "flv", "mts", "mkv"]
    spans = "".join(f"<span>.{e}</span>" for e in roll)
    return f"""<figure class="specimen" aria-label="Example: a file named lisbon-trip.mkv becomes lisbon-trip.mp4">
        <div class="file">
          <div class="doc-ico" aria-hidden="true">IN</div>
          <p class="fname" aria-hidden="true">lisbon-trip<span class="ext"><span class="roll">{spans}</span></span></p>
          <p class="fmeta">The file you have, in almost any format</p>
        </div>
        <div class="flux" aria-hidden="true"><img src="{root}assets/fluxa-mark.svg" alt="" width="54" height="54"></div>
        <div class="file out">
          <div class="doc-ico" aria-hidden="true">OUT</div>
          <p class="fname" aria-hidden="true">lisbon-trip.mp4</p>
          <p class="fmeta">The format your device, app or player wants</p>
        </div>
        <figcaption class="flux-note"><strong>Already H.264 and AAC inside?</strong> Fluxa re-wraps the file instead of re-encoding it: done in seconds, with no quality lost.</figcaption>
      </figure>"""


SHOT_ALTS = [
    "Fluxa on iPhone: the Home screen with recent conversions",
    "Fluxa on iPhone: choosing MP4 as the target format",
    "Fluxa on iPhone: the format grid grouped into video, audio and animated image",
    "Fluxa on iPhone: presets for devices and players",
    "Fluxa on iPhone: advanced codec and resolution settings",
    "Fluxa on iPhone: the batch queue with progress for each file",
]


def shots_html():
    d = SRC_SITE / "assets" / "shots"
    shots = sorted(d.glob("*.jpg")) if d.exists() else []
    if not shots:
        return ""
    items = "\n".join(f'        <li><img src="assets/shots/{p.name}" alt="{html.escape(SHOT_ALTS[i - 1] if i <= len(SHOT_ALTS) else "Fluxa on iPhone")}" width="660" loading="lazy" decoding="async"></li>'
                      for i, p in enumerate(shots, 1))
    return f"""  <section class="shots-section" aria-labelledby="h-shots">
    <div class="wrap">
      <h2 id="h-shots">See it in the app</h2>
      <ul class="shots">
{items}
      </ul>
    </div>
  </section>
"""


def tokens(items, cls=""):
    return f'<ul class="tokens {cls}">' + "".join(f"<li>{html.escape(t)}</li>" for t in items) + "</ul>"


def build_index():
    title = "Video Converter MP4 MKV: Fluxa | Convert any video and audio"
    desc = ("Free video converter for iPhone and iPad. Convert MKV, AVI, WebM, WMV, MOV and more to MP4, extract audio as "
            "MP3, make GIFs and convert in batches. Converted on your device, with no account.")
    faq_html = "\n".join(
        f'        <details><summary>{html.escape(q)}</summary><div class="answer">{a}</div></details>' for q, a in FAQ)
    presets = "\n".join(f"          <li><strong>{html.escape(n)}</strong><span>{html.escape(s)}</span></li>" for n, s in PRESETS)

    body = head(title, desc, "", jsonld_app() + jsonld_faq(FAQ), root="") + header("", "") + f"""
<main id="main">
  <section class="hero" aria-labelledby="h1">
    <div class="wrap">
      <div>
        <h1 id="h1">Any video, in the format you need.</h1>
        <p class="lede">Fluxa converts video and audio files on your iPhone and iPad: MKV, AVI, WebM and dozens more to MP4, MOV, MP3, GIF and other formats. It is free, there is no account, and your files never leave your device.</p>
        <p class="status">Not on the App Store yet</p>
        <p class="small hero-note">There is no download link yet. See the <a href="formats/">supported formats</a>, or ask a question on the <a href="support/">support page</a>.</p>
      </div>
      {specimen_html()}
    </div>
  </section>

{shots_html()}
  <section class="section" id="convert" aria-labelledby="h-convert">
    <div class="wrap">
      <h2 id="h-convert">Pick a format, tap Convert</h2>
      <div class="section-body">
        <p>Choose a video from Photos or Files, or drag it in on iPad. Pick the target from a grid grouped into Video, Audio and Animated image, then convert. Your original file is never changed.</p>
        <h3>Opens</h3>
        {tokens(TOKENS_IN)}
        <h3>Saves as</h3>
        {tokens(TOKENS_OUT, "out")}
        <p>And more: 24 output formats in all. See every format and codec on the <a href="formats/">formats page</a>.</p>
      </div>
    </div>
  </section>

  <section class="section band" id="presets" aria-labelledby="h-presets">
    <div class="wrap">
      <h2 id="h-presets">Presets for the place it is going</h2>
      <div class="section-body">
        <ul class="presets">
{presets}
        </ul>
        <p>Want more control? Advanced settings cover the video and audio codec, resolution from 4K down to 360p, frame rate, quality or bitrate, sample rate, trim, rotate and flip, metadata, and HDR to standard colour.</p>
      </div>
    </div>
  </section>

  <section class="section" id="more" aria-labelledby="h-more">
    <div class="wrap">
      <h2 id="h-more">Audio, GIFs and whole batches</h2>
      <div class="section-body">
        <dl class="defs">
          <div><dt>Extract audio</dt><dd>Save the sound of any video as MP3, M4A, WAV, FLAC, OGG, Opus, AIFF or AC3, or convert audio files between these formats.</dd></div>
          <div><dt>GIFs and animated images</dt><dd>Turn a clip into a GIF with an optimised colour palette, or into an animated WebP or APNG.</dd></div>
          <div><dt>Batch convert</dt><dd>Add several files to the queue and convert them in one go, with progress for each file.</dd></div>
          <div><dt>Formats guide</dt><dd>Not sure what to pick? The app explains what each format is best for, in one line each.</dd></div>
        </dl>
      </div>
    </div>
  </section>

  <section class="section band" id="private" aria-labelledby="h-private">
    <div class="wrap">
      <h2 id="h-private">Your files never leave your device</h2>
      <div class="section-body">
        <p>Fluxa has no account and no server that stores your files. Every conversion runs on your iPhone or iPad, with Apple's media frameworks and the open-source FFmpeg libraries. We run no analytics of our own.</p>
        <ul class="checks">
          <li>The iOS photo picker shows Fluxa only the videos you choose</li>
          <li>Saving to your library uses add-only permission</li>
          <li>Your original file is never overwritten</li>
          <li>No account, no sign-in, no subscription</li>
        </ul>
        <p>The only outside service is the ad network. The <a href="privacy/">privacy policy</a> explains what it collects.</p>
      </div>
    </div>
  </section>

  <section class="section" id="free" aria-labelledby="h-free">
    <div class="wrap">
      <h2 id="h-free">Free, and paid for by ads</h2>
      <div class="section-body">
        <p>Fluxa has no subscription and no in-app purchase. Ads from Google AdMob pay for it, in two places.</p>
        <div class="split">
          <div>
            <h3>Where you see ads</h3>
            <ul>
              <li>A banner on the Home screen, never over the conversion controls.</li>
              <li>One short video, which you choose to watch, when you save or share. It covers the whole export, even a batch, and further exports for 2 minutes.</li>
            </ul>
          </div>
          <div>
            <h3>When no ad is available</h3>
            <ul>
              <li>Your export goes ahead for free.</li>
              <li>This happens, for example, when you are offline.</li>
            </ul>
          </div>
        </div>
        <p>Where the law requires it, the app shows a consent form from Google before personalised ads, and iOS may ask whether the app may track you. You can say no and still use everything.</p>
      </div>
    </div>
  </section>

  <section class="section band" id="limits" aria-labelledby="h-limits">
    <div class="wrap">
      <h2 id="h-limits">What it cannot do</h2>
      <div class="section-body">
        <div class="limit">
          <p>Fluxa cannot convert DRM-protected files, such as films bought or rented from a store or downloaded from a streaming service, or encrypted files. Some very old or rare codecs may not open. Saving as HEVC needs a device with a hardware HEVC encoder.</p>
        </div>
        <p>When a file cannot be converted, Fluxa says so and explains why.</p>
      </div>
    </div>
  </section>

  <section class="section faq" id="faq" aria-labelledby="h-faq">
    <div class="wrap">
      <h2 id="h-faq">Questions</h2>
      <div class="section-body">
{faq_html}
      </div>
    </div>
  </section>
</main>
""" + footer("")
    (OUT / "index.html").write_text(body, encoding="utf-8")


# ----------------------------------------------------------------------------- formats
def build_formats():
    title = f"Supported formats | {SITE_NAME}"
    desc = ("Every format Fluxa opens and saves: 12 video, 9 audio and 3 animated image output formats with their codecs, "
            "the input formats it reads, and the honest limits (DRM, encrypted files, rare codecs).")
    tables = []
    for cat, rows in FORMATS_OUT.items():
        has_video = cat != "Audio"
        vhead = "Video" if cat == "Video" else "Frames"
        th = "<tr><th scope=\"col\">Format</th><th scope=\"col\">Best for</th>" + (f"<th scope=\"col\">{vhead}</th>" if has_video else "") + "<th scope=\"col\">Audio</th></tr>"
        body_rows = "\n".join(
            f"<tr><th scope=\"row\">{html.escape(f)}</th><td class=\"best\" data-label=\"Best for\">{html.escape(b)}</td>"
            + (f"<td data-label=\"{vhead}\">{html.escape(v)}</td>" if has_video else "") + f"<td data-label=\"Audio\">{html.escape(a)}</td></tr>"
            for f, b, v, a in rows)
        cid = "out-" + cat.lower().replace(" ", "-")
        tables.append(f"""        <div class="table-scroll" role="region" aria-labelledby="{cid}" tabindex="0">
          <table class="fmt">
            <caption id="{cid}">{html.escape(cat)}: {len(rows)} formats</caption>
            <thead>{th}</thead>
            <tbody>
{body_rows}
            </tbody>
          </table>
        </div>""")
    ins = "\n".join(f"          <div><h3>{html.escape(t)}</h3><p>{html.escape(x)}</p></div>" for t, x in FORMATS_IN)
    body = head(title, desc, "formats/", root="../") + header("../", "formats") + f"""
<main id="main">
  <div class="page">
    <div class="wrap">
      <div class="wide">
        <h1>Supported formats</h1>
        <p class="lede">What Fluxa opens, what it saves, and what it cannot do. Codecs are listed best first; the first one is the default.</p>
        <h2>Formats it saves</h2>
        <p class="small">When the source already uses codecs the new format can hold, Fluxa re-wraps the file without re-encoding: it takes seconds and nothing is lost. H.264 and HEVC use the device's hardware encoder.</p>
{chr(10).join(tables)}
        <h2>Formats it opens</h2>
        <p class="small">Apple formats are read by iOS itself; the rest are read with the FFmpeg libraries inside the app. Both run on your device.</p>
        <div class="ingroups">
{ins}
        </div>
        <h2>What it cannot convert</h2>
        <div class="limit">
          <p><strong>DRM-protected files</strong>, such as films and shows bought or rented from a store or downloaded from a streaming service. Fluxa does not remove copy protection.</p>
          <p><strong>Encrypted or password-protected files.</strong></p>
          <p><strong>Some very old or rare codecs</strong>, and damaged files whose data cannot be read.</p>
          <p><strong>HEVC output on devices without a hardware HEVC encoder.</strong> Choose H.264 instead.</p>
        </div>
        <p>Some formats cannot hold everything the source has: a GIF has no sound and at most 256 colours per frame, and some formats cannot carry subtitles or more than one audio track. Fluxa shows a clear message when a file cannot be converted, instead of failing quietly. If a file you think should work does not, write to {EMAIL_TEXT} and tell us the format.</p>
      </div>
    </div>
  </div>
</main>
""" + footer("../")
    (OUT / "formats").mkdir(exist_ok=True)
    (OUT / "formats" / "index.html").write_text(body, encoding="utf-8")


# ----------------------------------------------------------------------------- licences
LIBS = [
    ("FFmpeg (libavformat, libavcodec, libavfilter, libswscale, libswresample, libavutil)", "GNU LGPL 2.1 or later", "https://ffmpeg.org/legal.html"),
    ("libvpx (VP8 and VP9)", "BSD 3-Clause", "https://chromium.googlesource.com/webm/libvpx/"),
    ("libopus (Opus)", "BSD 3-Clause", "https://opus-codec.org/license/"),
    ("libvorbis and libogg (Vorbis, Ogg)", "BSD 3-Clause", "https://xiph.org/licenses/bsd/"),
    ("LAME (libmp3lame, MP3)", "GNU LGPL 2.1 or later", "https://lame.sourceforge.io/"),
    ("libtheora (Theora)", "BSD 3-Clause", "https://www.theora.org/"),
    ("libwebp (WebP)", "BSD 3-Clause", "https://chromium.googlesource.com/webm/libwebp/"),
    ("dav1d (AV1 decoding)", "BSD 2-Clause", "https://code.videolan.org/videolan/dav1d"),
    ("Google Mobile Ads SDK and User Messaging Platform", "Google's terms", "https://developers.google.com/admob/terms"),
]


def build_licenses():
    title = f"Open-source licences | {SITE_NAME}"
    desc = "Fluxa uses the FFmpeg libraries under the GNU LGPL 2.1 or later, linked dynamically and replaceable, plus libvpx, libopus, libvorbis, LAME, libtheora, libwebp and dav1d. Source offer and notices."
    rows = "\n".join(f'<tr><th scope="row">{html.escape(n)}</th><td data-label="Licence">{html.escape(l)}</td><td data-label="Project"><a href="{u}" rel="noopener">{html.escape(u.split("//")[1].split("/")[0])}</a></td></tr>'
                     for n, l, u in LIBS)
    body = head(title, desc, "licenses/", root="../") + header("../", "") + f"""
<main id="main">
  <div class="page">
    <div class="wrap">
      <article class="doc">
        <h1>Open-source licences</h1>
        <p class="lede">Fluxa is built on open-source software. This page lists it, explains your rights under its licences, and tells you how to get the source code.</p>
        <h2>FFmpeg, under the LGPL</h2>
        <p>Fluxa uses libraries from the FFmpeg project (<a href="https://ffmpeg.org" rel="noopener">ffmpeg.org</a>), licensed under the GNU Lesser General Public License version 2.1 or later (LGPL). They are built without the GPL and non-free options, so no part of FFmpeg in Fluxa is under the GPL.</p>
        <ul>
          <li>The FFmpeg libraries are included as a separate, dynamically linked framework (FFmpegLGPL.framework) inside the app. You may replace it with a modified version of the same libraries.</li>
          <li>No changes were made to the FFmpeg source code. The exact versions and the build script are published in the public repository <a href="https://github.com/EcomswiftLLC/ffmpeg-ios-lgpl" rel="noopener">github.com/EcomswiftLLC/ffmpeg-ios-lgpl</a> (see scripts/build.sh and scripts/versions.env), and the FFmpeg source releases are at <a href="https://ffmpeg.org/releases/" rel="noopener">ffmpeg.org/releases</a>.</li>
          <li>Nothing in Fluxa's terms of use limits your rights under the LGPL, including modifying the libraries and reverse engineering the app to debug such modifications.</li>
          <li>The full licence text is at <a href="https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html" rel="noopener">gnu.org/licenses/old-licenses/lgpl-2.1.html</a>.</li>
        </ul>
        <h2>Written offer for the source code</h2>
        <p>For at least three years from the date you received a version of Fluxa, Ecom Swift LLC will give anyone who asks a complete copy of the corresponding source code of the LGPL libraries in that version, including the build scripts, for no more than the cost of providing it (usually nothing, as a download link). Write to {EMAIL_TEXT} and tell us your Fluxa version, which you can see in Settings.</p>
        <h2>Components and their licences</h2>
        <div class="table-scroll" role="region" aria-labelledby="libs-cap" tabindex="0">
          <table class="fmt lib">
            <caption id="libs-cap">Third-party components</caption>
            <thead><tr><th scope="col">Component</th><th scope="col">Licence</th><th scope="col">Project</th></tr></thead>
            <tbody>
{rows}
            </tbody>
          </table>
        </div>
        <p>BSD licensed components are copyright their respective authors and are used under their licences, which allow redistribution in binary form with this notice. The full notices are also in the app, in Settings under Open-source licences.</p>
        <h2>Codecs and patents</h2>
        <p>H.264, HEVC and ProRes video are encoded with Apple's VideoToolbox, and AAC with Apple's audio frameworks, which are part of iOS. Some codecs may be covered by patents in some countries.</p>
        <h2>Trademarks</h2>
        <p>FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project. Fluxa and Ecom Swift LLC are not affiliated with or endorsed by the FFmpeg project.</p>
        <p class="small">Last updated: November 19, 2026.</p>
      </article>
    </div>
  </div>
</main>
""" + footer("../")
    (OUT / "licenses").mkdir(exist_ok=True)
    (OUT / "licenses" / "index.html").write_text(body, encoding="utf-8")


# ----------------------------------------------------------------------------- support
def build_support():
    title = f"Support | {SITE_NAME}"
    desc = "Get help with Fluxa: contact details, and answers about converting videos, formats that will not open, ads and saving your files."
    items = [
        ("How do I convert a video to MP4?",
         "<ol><li>On the Home screen, choose a video from Photos or Files. On iPad you can also drag a file in.</li><li>Tap MP4 in the format grid, or the Universal MP4 preset.</li><li>Tap Convert and wait for the progress to finish.</li><li>Tap Save or Share.</li></ol>"),
        ("How do I extract the audio from a video?",
         "<p>Choose the video, then pick MP3, M4A, WAV or another format in the Audio group of the format grid, or use the Audio only preset. Fluxa saves only the sound.</p>"),
        ("A file will not open or convert",
         "<p>Fluxa shows the reason. The most common ones:</p><ul><li><strong>Protected file:</strong> films and shows bought or rented from a store, or downloaded from a streaming service, use DRM. These cannot be converted.</li><li><strong>Encrypted file:</strong> password-protected files cannot be read.</li><li><strong>Damaged or incomplete file:</strong> try copying it to your device again.</li><li><strong>Rare codec:</strong> some very old or unusual codecs are not supported. Tell us the format and we will look at it.</li></ul>"),
        ("Why is my converted file larger or smaller than the original?",
         "<p>File size depends on the codec, the resolution and the quality you choose. Lossless formats such as WAV, FLAC and ProRes are large. Re-wrapping (for example MKV with H.264 to MP4) keeps almost the same size. Choose a lower resolution or quality in Advanced for a smaller file.</p>"),
        ("Why does HEVC not appear on my device?",
         "<p>Saving as HEVC uses the hardware encoder in your device, which some older iPhone and iPad models do not have. Choose H.264, which plays on almost everything.</p>"),
        ("Why am I asked to watch an ad?",
         "<p>Fluxa is free, and ads pay for it. When you save or share, the app offers one short video that you choose to watch. One watched ad covers that export, even a whole batch, and further exports for 2 minutes. If you choose Not now, nothing is saved. If no ad is available, for example when you are offline, the export goes ahead without one.</p>"),
        ("My conversion is slow or stops",
         "<p>Re-encoding long or 4K videos takes time and battery, especially on older devices. Keep Fluxa open until the conversion finishes, make sure there is free storage, and try a lower resolution. Re-wrapping is much faster than re-encoding, so pick a format that can hold the original codecs when you can.</p>"),
        ("I saw an ad that seems wrong",
         "<p>Write to us at the address above. Tell us roughly when and where in the app you saw it and what it showed. A screenshot helps. We block ad categories and advertisers through Google AdMob where we can.</p>"),
        ("I want to change my ad or tracking choice",
         "<p>Open Settings in the app and look for the Ad privacy choices row, which appears where the law requires it. You can also change tracking in iOS Settings under Privacy and Security, then Tracking.</p>"),
        ("Where can I get the FFmpeg source code?",
         "<p>See the <a href=\"../licenses/\">open-source licences</a> page. It links the build scripts and the exact source, and explains how to ask us for a copy.</p>"),
    ]
    faq_html = "\n".join(f'          <details><summary>{html.escape(q)}</summary><div class="answer">{a}</div></details>' for q, a in items)
    body = head(title, desc, "support/", jsonld_faq(items), root="../") + header("../", "support") + f"""
<main id="main">
  <div class="page">
    <div class="wrap">
      <div class="doc">
        <h1>Support</h1>
        <p class="lede">Write to us and a person will read it.</p>
        <p class="contact-line">{EMAIL_TEXT}</p>
        <p class="small">Select the address to copy it into your mail app.</p>
        <p>We reply by email. A message gets answered faster when it includes:</p>
        <ul>
          <li>your iPhone or iPad model and iOS or iPadOS version</li>
          <li>the format of the file and the format you chose</li>
          <li>what happened, and the message Fluxa showed</li>
          <li>a screenshot, if it helps</li>
        </ul>
        <p>Please do not send the video itself unless we ask for it.</p>
        <p>Fluxa is not on the App Store yet, so support right now covers questions about the app before it is available.</p>
        <h2>Common questions</h2>
        <div class="faq">
{faq_html}
        </div>
        <h2>Company</h2>
        <p>Ecom Swift LLC<br>30 N Gould St #37906<br>Sheridan, WY 82801<br>United States</p>
        <p>Read the <a href="../privacy/">privacy policy</a>, the <a href="../terms/">terms of use</a> and the <a href="../licenses/">open-source licences</a>.</p>
      </div>
    </div>
  </div>
</main>
""" + footer("../")
    (OUT / "support").mkdir(exist_ok=True)
    (OUT / "support" / "index.html").write_text(body, encoding="utf-8")


# ----------------------------------------------------------------------------- legal (markdown -> html)
URL_RE = re.compile(r"(https?://[^\s<)]+)")
MAIL_RE = re.compile(r"([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})")


def inline(text):
    t = html.escape(text, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)

    def url(m):
        u = m.group(1)
        trail = ""
        while u and u[-1] in ".,;":
            trail = u[-1] + trail
            u = u[:-1]
        return f'<a href="{u}" rel="noopener">{u}</a>{trail}'

    t = URL_RE.sub(url, t)
    parts = re.split(r"(<a .*?</a>)", t)
    parts = [p if p.startswith("<a ") else MAIL_RE.sub(r'<span class="email">\1</span>', p) for p in parts]
    return "".join(parts)


def md_to_html(md):
    md = re.sub(r"<!-- DRAFT-NOTICE-START -->.*?<!-- DRAFT-NOTICE-END -->", "", md, flags=re.S)
    out, para, items = [], [], []
    title = ""
    meta_open = False
    seen_h2 = False

    def flush_para():
        nonlocal para
        if para:
            out.append("<p>" + "<br>".join(inline(p) for p in para) + "</p>")
            para = []

    def flush_list():
        nonlocal items
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items = []

    for raw in md.splitlines():
        line = raw.rstrip()
        if line.startswith("# "):
            flush_para(); flush_list()
            title = line[2:].strip()
            out.append(f"<h1>{html.escape(title)}</h1>")
        elif line.startswith("## "):
            flush_para(); flush_list()
            if meta_open:
                out.append("</div>"); meta_open = False
            seen_h2 = True
            out.append(f"<h2>{inline(line[3:].strip())}</h2>")
        elif line.startswith("- "):
            flush_para()
            items.append(line[2:].strip())
        elif not line.strip():
            flush_para(); flush_list()
        elif line.startswith("**") and title and not seen_h2:
            if not meta_open:
                out.append('<div class="meta">'); meta_open = True
            out.append("<p>" + inline(line) + "</p>")
        else:
            flush_list()
            if meta_open:
                out.append("</div>"); meta_open = False
            para.append(line.strip())
    flush_para(); flush_list()
    if meta_open:
        out.append("</div>")
    return title, "\n".join(out)


def build_legal(src, folder, current_title, desc):
    md = (LEGAL / src).read_text(encoding="utf-8")
    title, content = md_to_html(md)
    page_title = f"{current_title} | {SITE_NAME}"
    body = head(page_title, desc, folder + "/", root="../") + header("../", "") + f"""
<main id="main">
  <div class="page">
    <div class="wrap">
      <article class="doc">
{content}
      </article>
    </div>
  </div>
</main>
""" + footer("../")
    (OUT / folder).mkdir(exist_ok=True)
    (OUT / folder / "index.html").write_text(body, encoding="utf-8")


def build_misc():
    urls = ["", "formats/", "support/", "privacy/", "terms/", "licenses/"]
    xml = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for u in urls:
        xml.append(f"  <url><loc>{BASE}{u}</loc><lastmod>{UPDATED}</lastmod></url>")
    xml.append("</urlset>")
    (OUT / "sitemap.xml").write_text("\n".join(xml) + "\n", encoding="utf-8")
    (OUT / "robots.txt").write_text(
        "# Hosted on GitHub Pages as a project path under /fluxa/.\n"
        "User-agent: *\nAllow: /\n\n"
        f"Sitemap: {BASE}sitemap.xml\n", encoding="utf-8")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if OUT != SRC_SITE:
        shutil.copytree(SRC_SITE / "assets", OUT / "assets", dirs_exist_ok=True)
    build_index()
    build_formats()
    build_support()
    build_licenses()
    build_legal("privacy-policy.md", "privacy", "Privacy Policy",
                "How Video Converter MP4 MKV: Fluxa handles information: files are converted on your device and never uploaded, there is no account, and ads come from Google AdMob with your consent where required.")
    build_legal("terms-of-use.md", "terms", "Terms of Use",
                "The terms for using Video Converter MP4 MKV: Fluxa, a free video and audio converter supported by ads.")
    build_misc()
    print("site built in", OUT)


if __name__ == "__main__":
    main()
