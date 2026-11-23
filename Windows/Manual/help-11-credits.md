# Credits and Licences

## DownAudible

DownAudible is developed by Ashley Cox and is free software under the GNU Affero General Public License, version 3. Choose **Help > About DownAudible** for the installed version.

- [DownAudible source and issues](https://github.com/ashleycox/DownAudible)
- [Ashley Cox](https://ashleycox.co.uk)

## Windows interface and runtime

The Windows app uses [Python](https://www.python.org/), [wxPython](https://wxpython.org/), [wxWidgets](https://www.wxwidgets.org/), and [Python-Markdown](https://python-markdown.github.io/) to render the offline manual. The installer uses [NSIS](https://nsis.sourceforge.io/).

## Audio and service components

The Windows distribution bundles patched [FFmpeg](https://ffmpeg.org/) and [LAME](https://lame.sourceforge.io/) for audio processing. The Audible helper uses the Python [audible](https://github.com/mkb79/Audible) and [audible-cli](https://github.com/mkb79/audible-cli) projects. Their dependencies provide HTTP transport, certificate data, encryption, and image processing. The distribution includes licence and source information in its resources.

The optional Widevine stereo download feature uses pywidevine, which is licensed under the GNU General Public License, version 3. Michael Bucari maintains the [CDM provisioning service](https://github.com/mkb79/audible-cli/issues/155#issuecomment-2788239962) used when you enable Widevine stereo for an account.

[pywidevine source and licence](https://github.com/devine-dl/pywidevine/tree/v1.9.0)

## Development tools

The Windows media tools and launcher use [LLVM-MinGW](https://github.com/mstorsjo/llvm-mingw). [uv](https://docs.astral.sh/uv/) installs the locked helper dependencies for the target architecture.

## Support DownAudible

If you like DownAudible and you’d like to support my work, you can [make a donation](https://www.paypal.com/donate/?hosted_button_id=WMLX4PLED9PRE). There’s no pressure or hard sell. DownAudible is and always will be free.
