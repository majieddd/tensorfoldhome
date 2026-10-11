# Third-party notices

TensorFold Home is an unofficial companion app for TensorFold. It is not affiliated with TensorFold, its author, or
Strata.

## TensorFold (Apache License 2.0)

https://github.com/ashhart/TensorFold, by ashhart and contributors, Apache License 2.0.

TensorFold Home does not include TensorFold's code. **Set up** installs TensorFold from its official sources (the
`ashhart/tensorfold` Homebrew tap and the repository's `python-0.6` branch). The app then starts TensorFold's own
`tensorfold serve` and talks to its local HTTP API (`/health`, `/metrics`, `/v1/chat/completions`, `/v1/messages`).
`backend/bin/tf06_no_tensor_units.py` imports TensorFold 0.6 and replaces two of its device checks at run time
(see that file).

## StrataHome and Strata (MIT)

The window's look and layout come from [StrataHome](https://github.com/majieddd/stratahome) (MIT, Copyright (c) 2026
majieddd). StrataHome took its colour and type tokens, component styles and the Monitor's layout from the web app that
[Strata](https://github.com/Niko1221/Strata) serves:

> MIT License
>
> Copyright (c) 2026 Niko1221 and the Strata contributors
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files
> (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge,
> publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
> subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
> ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Open WebUI (optional)

https://github.com/open-webui/open-webui. Only installed when you ask for it (`install.sh --webui`, or the checkbox
under Server > Set up). It is installed from PyPI and runs under its own licence.

## Outfit (SIL Open Font License 1.1)

The UI font, `assets/fonts/Outfit-*.ttf`, Copyright 2021 The Outfit Project Authors. The licence is in
`assets/fonts/OFL.txt`. The fonts are bundled in the app.
