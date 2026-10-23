#!/bin/zsh
set -eu
cd "${0:A:h}"
releaseVersion=$(cat VERSION)
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "Commit the release sources before packaging so the source archive matches the app."
  exit 1
fi
ISCSI_APP_OUTPUT="dist/public/SynologyInitiator.app" zsh build-app.sh
releaseName="macOS-iSCSI-Initiator-${releaseVersion}-macos-arm64"
releaseStage="dist/${releaseName}"
mkdir -p "$releaseStage/docs"
ditto dist/public/SynologyInitiator.app "$releaseStage/SynologyInitiator.app"
cp dist/iscsi "$releaseStage/iscsi"
cp LICENSE README.md README_RU.md "$releaseStage/"
cp docs/GUIDE_RU.md docs/ARCHITECTURE.md docs/VALIDATION.md "$releaseStage/docs/"
ditto -c -k --sequesterRsrc --keepParent "$releaseStage" "dist/${releaseName}.zip"
git archive --format=zip --prefix="macOS-iSCSI-Initiator-${releaseVersion}-source/" --output="dist/macOS-iSCSI-Initiator-${releaseVersion}-source.zip" HEAD
cp docs/GUIDE_RU.md dist/GUIDE_RU.md
(
  cd dist
  shasum -a 256 "${releaseName}.zip" "macOS-iSCSI-Initiator-${releaseVersion}-source.zip" GUIDE_RU.md > SHA256SUMS.txt
)
echo "Release archives and SHA256SUMS.txt are in dist/."
