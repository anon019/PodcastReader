# Podcast Reader · Native design contract

- Visual thesis: a calm macOS editorial reader that feels like warm paper in light mode and an ink-green reading room in dark mode; content and freshness are louder than chrome.
- Content plan: daily/unread scope → episode list with original and organized dates → high-resolution episode image → title and freshness receipt → one-sentence takeaway → participants → topic map → core insights → evidence limits → bilingual Transcript.
- Interaction thesis: three-column selection preserves context; reading/Transcript transitions are short and restrained; appearance follows the saved System/Light/Dark choice; font size and read state respond immediately without hiding content.
- Typography: SF system typography for navigation and controls, PingFang SC for Chinese long-form body, Songti SC for editorial summaries, and system serif for English Transcript. Default body is 17 pt and adjustable from 15–22 pt.
- Palette: adaptive paper, chrome, surface, ink, muted, sage action, amber original-publication accent, and restrained dividers. Every fixed light surface must have an explicit dark counterpart.
- Layout: native `NavigationSplitView`; source library 178–245 pt, episode inbox 310–430 pt, flexible reader with a 780 pt article measure and 980 pt bilingual measure.
- Component families: plain navigation rows, thumbnail episode rows, two-line freshness receipts, one summary callout, participant/topic sections, numbered insights, and native sheets/toolbars. Cards exist only where they group one reading object.
- Density: compact navigation, scan-friendly episode list, generous long-form rhythm. No note editor, dashboard mosaic, prompt controls, ornamental gradients, or resident-task controls.
- Responsive order: preserve the reader first, collapse source navigation next, then the episode list; never squeeze the article below a readable measure.
