# Third-party notices

This directory is part of the uFVS source tree and is also copied into the
standalone desktop releases. It records material that is not covered by the
root `LICENSE`.

The release build regenerates `components.csv` and the package subdirectories
from the exact R library staged into that release. The inventory includes the
transitive dependency closure, declared license expressions, upstream URLs,
author/copyright fields where supplied, and license or notice files found in
each package. A package's declared license is not changed to MIT by uFVS.

The bundled R runtime retains the R Project's own license and copyright files.
The bundled FVS engine retains the USDA Forest Vegetation Simulator terms and
the source revision is recorded in `BUILD_INFO.json` and the FVS reference
files. The FVS source's NVEL submodule is separately identified in
`FVS/NVEL-source-reference.txt`. The FVS Interface material reproduced by uFVS
retains its own terms.

To prepare corresponding source archives for a particular staged release, use:

```bash
Rscript tools/download_third_party_source.R \
  --inventory path/to/release/THIRD_PARTY/components.csv \
  --out path/to/third-party-source
```

That helper records download URLs and stops on an unavailable archive rather
than silently substituting a different version. Whether a source archive must
accompany a particular redistribution should be reviewed against the exact
package terms before publishing a release.
