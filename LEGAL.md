# YouTube and Content Use

This repository is an independent personal reader. It is not affiliated with, endorsed by, or sponsored by YouTube, Google, OpenAI, or any Podcast publisher.

## Public-release decision

The source code is public, but YouTube caption extraction is **disabled by default**. The application does not bundle captions, Transcripts, API credentials, cookies, account sessions, audio, or a circumvention mechanism. A user must install the external tools and deliberately enable caption extraction on their own Mac.

Use the extraction capability only for content that you own, administer, have permission to process, or are otherwise legally entitled to use. Keep the resulting Transcript and analysis local unless the rights holder authorizes redistribution. The MIT license covers this repository's code and original artwork; it grants no rights to third-party content, names, logos, thumbnails, or captions.

[YouTube's Terms](https://www.youtube.com/static?template=terms) restrict automated access and downloading except where authorized by the service or rights holders. The official [YouTube Data API caption download method](https://developers.google.com/youtube/v3/docs/captions/download) also requires permission to edit the video, so it is not a general substitute for public third-party Podcast captions. This project therefore cannot promise that a particular extraction use is permitted. Users are responsible for reviewing current platform terms and applicable law.

## Explicit local enablement

After reviewing this file, an authorized user can enable the local external-caption path with either:

```zsh
export PODCAST_READER_ENABLE_YOUTUBE_CAPTIONS=1
```

for one process, or by creating this local marker:

```zsh
mkdir -p "$HOME/Library/Application Support/PodcastNotes"
touch "$HOME/Library/Application Support/PodcastNotes/allow-youtube-caption-extraction"
```

The marker is outside the repository and must never be committed. Remove it to return to the public default.
