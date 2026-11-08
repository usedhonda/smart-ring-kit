# Embedding and license notes

The original implementation, documentation and synthetic fixtures in this
repository are distributed under [MIT](../LICENSE).

## Using SmartRingKit in an app

MIT permits commercial use, modification and redistribution, including use in a
closed-source app. It does not require publishing your application's source code
or licensing that whole application under MIT. When redistributing SmartRingKit
or substantial portions, preserve its copyright and permission notice. A practical
app integration is to bundle the full, unchanged `LICENSE` text in your OSS notices
or acknowledgements screen and include it with source distributions.
Swift Package Manager fetching a license does not by itself create an OSS notices
screen in the distributed app; the host developer must arrange notice inclusion.
See the [MIT text published by OSI](https://opensource.org/license/mit).

Do not present this unofficial library as manufacturer-endorsed. MIT's grant and
warranty disclaimer do not establish that unrelated third-party SDKs, trademarks,
patents, account APIs or firmware are licensed to you. This note explains project
policy and the license text; it is not a jurisdiction-specific legal clearance.

## Reference SDK boundary

The protocol document records pinned public references used to understand formats.
No reference SDK source, binaries, firmware or vendor assets are redistributed in
this repository. The original Swift implementation is MIT; that does not relicense
any upstream material. The reference repository's redistribution license was not
identified. Do not bundle or copy it under the assumption that this project's MIT
license covers it. Referencing code while writing an implementation is not itself
a blanket clearance of third-party rights; keep provenance and assess any concrete
restriction before introducing that material.

Contributors must submit work they can license under MIT and document new external
code/dependencies with their actual licenses/notices. New platform implementations
follow the same rule. Device compatibility evidence and vendor names are used to
explain tested behavior, not to claim affiliation or permission from the vendor.
