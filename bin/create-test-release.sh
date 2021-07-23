#!/usr/bin/env bash

GITHUB_ACCOUNT='woocommerce'
GITHUB_PROJECT='woocommerce-gateway-stripe'

set -euo pipefail
IFS=$'\n\t'

if [[ $(dirname "$0") != './bin' && $(dirname "$0") != 'bin' ]]; then
	echo "This script must be run from the root of the '$GITHUB_PROJECT' repo"
	exit 1
fi

if [ $# -lt 1 ]; then
	echo "Usage: $0 <version>"
	exit 1
fi

VERSION=$1
SUFFIX='test'

GITHUB_TOKEN='' # TODO: attempt to read this from ~/.woorelease/config
CREATE_LOCAL_BRANCH=false
CREATE_REMOTE_BRANCH=false

abort() {
	echo
	echo "Aborted."
	exit 1
}

check_prerequisites() {
	command -v git >/dev/null 2>&1 || {
		echo "Git is not installed"
		abort
	}
	command -v svn >/dev/null 2>&1 || {
		echo "Subversion is not installed"
		abort
	}
	command -v php >/dev/null 2>&1 || {
		echo "PHP is not installed"
		abort
	}

	# Check for Woorelease phar file
	if [[ ! -f ".cache/woorelease.phar" ]]; then
		mkdir -p .cache

		echo "Woorelease not found."
		read -p "To automatically download it, paste your GitHub token: " -r
		if [[ -z "$REPLY" ]]; then
			echo
			echo "You will need to download it from: https://github.com/woocommerce/woorelease/releases/latest, and extract it into .cache/ manually"
			abort
		fi

		GITHUB_TOKEN=$REPLY

		response=$(curl -s --header "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/woocommerce/woorelease/releases/latest)
		download_url=$(echo "$response" | php -r '$assets = json_decode( file_get_contents( "php://stdin" ) )->assets; foreach ( $assets as $asset ) { if ( $asset->name === "woorelease.zip") { $url = $asset->url; break; } }; print_r( $url );')
		if [[ -z "$download_url" ]]; then
			echo "Unable to download Woorelease, verify your GitHub token"
			echo "Download it from: https://github.com/woocommerce/woorelease/releases/latest, and extract it into the .cache/ folder manually"
			abort
		fi

		http_code=$(curl -sL --header "Authorization: token $GITHUB_TOKEN" --header 'Accept: application/octet-stream' $download_url --output .cache/woorelease.zip --write-out "%{http_code}")
		if [[ ${http_code} -lt 200 || ${http_code} -gt 299 ]]; then
			echo "Unable to download Woorelease zip package (status_code: $http_code)"
			echo "Download it from: https://github.com/woocommerce/woorelease/releases/latest, and extract it into the .cache/ folder manually"
			abort
		fi

		unzip .cache/woorelease.zip -d .cache >/dev/null
		rm .cache/woorelease.zip
		echo "Woorealease successfully downloaded to '.cache/woorelease.phar'."
	fi

	# Check for Woorelease config file
	if [[ ! -f ~/.woorelease/config ]]; then
		echo "Woorelease config file not found (~/.woorelease/config)."
		echo "Please follow the configuration steps here: https://github.com/woocommerce/woorelease#prerequisites-for-configuration"
		abort
	fi
}

check_github_status() {
	echo
	echo "Checking GitHub project status..."

	# Check that the local repo is in a clean state
	if ! [ -z "$(git status --untracked-files=no --porcelain)" ]; then
		echo
		echo "You have unstaged/uncommited changes, please commit or stash them, and then re-run this script."
		abort
	fi

	# Check if a local branch 'release/VERSION' already exists
	git branch | grep "release/$VERSION" >/dev/null || {
		CREATE_LOCAL_BRANCH=true
	}

	# Check if the remote branch 'release/VERSION' already exists
	git ls-remote --exit-code --heads origin release/$VERSION >/dev/null || {
		CREATE_REMOTE_BRANCH=true
	}

	# If tag VERSION-test exists, calculate the next test suffix to use (ex: 5.3.0-test3)
	set +e
	git ls-remote --exit-code --tags origin "refs/tags/$VERSION-test" >/dev/null
	if [ $? -eq 0 ]; then
		next=2
		while true; do
			git ls-remote --exit-code --tags origin "refs/tags/$VERSION-test$next" >/dev/null || break
			next=$((next + 1))
		done
		SUFFIX="${SUFFIX}${next}"
	fi
	set -e
}

print_summary() {
	if $CREATE_REMOTE_BRANCH && ! $CREATE_LOCAL_BRANCH; then
		echo
		echo "A local branch named release/$VERSION already exists, but has not been pushed to the remote repository."
		echo
		echo "Make sure that both readme.txt and changelog.txt have the correct entries for the release version:"
		echo "  = $VERSION - $(date +'%Y')-xx-xx ="
		echo "Push the branch to the remote repository, and re-run this script."
		abort
	fi

	echo
	echo "This script will perform the following actions:"
	$CREATE_REMOTE_BRANCH && echo "  - Create a new branch named 'release/$VERSION' using 'develop' as base and push it to GitHub"
	echo "  - Run Woorelease simulation locally with version=$VERSION (using the 'release/$VERSION' branch)"
	echo "  - Create a new tag named '$VERSION-$SUFFIX' in GitHub"
	echo "  - Create a new release named '$VERSION-$SUFFIX' in GitHub (marked as 'pre-release')"
	echo "  - Upload the generated plugin zip file ($GITHUB_PROJECT.zip) to the newly created release in GitHub"
}

create_git_branch() {
	echo
	echo "This is the first test release for $VERSION, creating a remote 'release/$VERSION' branch..."
	echo

	echo "> git checkout develop && git pull"
	git checkout develop && git pull

	echo "> git checkout -b release/$VERSION"
	git checkout -b release/$VERSION

	echo
	echo "Checking/updating version number in changelog.txt and readme.txt"
	sed -i '' -r "s/^= [0-9]+.x.x - (.*)$/= $VERSION - \1/" readme.txt
	sed -i '' -r "s/^= [0-9]+.x.x - (.*)$/= $VERSION - \1/" changelog.txt

	grep "^= $VERSION - $(date +'%Y')-xx-xx =" changelog.txt >/dev/null &&
		grep "^= $VERSION - $(date +'%Y')-xx-xx =" readme.txt >/dev/null ||
		{
			echo "Make sure that both readme.txt and changelog.txt have the correct entries for the release version, ex:"
			echo "  = $VERSION - $(date +'%Y')-xx-xx ="
			echo "Push this branch (release/$VERSION) to the remote repository, and re-run this script."
			abort
		}

	echo "> git add changelog.txt && git commit -m 'Set next release version'"
	git add changelog.txt readme.txt && git commit -m 'Set next release version'

	echo
	echo "> git push origin release/$VERSION"
	git push origin release/$VERSION
}

create_test_package() {
	# We simulate creating the release with the version number VERSION (ex: 5.3.0) and not the current test version (ex: 5.3.0-test)
	echo
	echo "> php .cache/woorelease.phar simulate --product_version=$VERSION https://github.com/$GITHUB_ACCOUNT/$GITHUB_PROJECT/tree/release/$VERSION"
	set +e
	output=$(php .cache/woorelease.phar simulate --product_version=$VERSION https://github.com/$GITHUB_ACCOUNT/$GITHUB_PROJECT/tree/release/$VERSION | tee /dev/stderr)
	[ $? -eq 0 ] || abort
	set -e

	# Update the 'Version' tag in the plugin headers to the current VERSION-PREFFIX
	zip_file=$(echo $output | sed -n "s/.*Skipping upload of asset \(.*\) to GH release.*/\1/p")

	cd "$(dirname "$zip_file")/.."

	echo
	echo "> sed -i '' \"s/^ \* Version: .*$/ * Version: $VERSION-$SUFFIX/\" $GITHUB_PROJECT/$GITHUB_PROJECT.php"
	sed -i '' "s/^ \* Version: .*$/ * Version: $VERSION-$SUFFIX/" $GITHUB_PROJECT/$GITHUB_PROJECT.php

	echo
	echo "> zip --update '$GITHUB_PROJECT/$GITHUB_PROJECT.zip' '$GITHUB_PROJECT/$GITHUB_PROJECT.php"
	zip --delete "$GITHUB_PROJECT/$GITHUB_PROJECT.zip" "$GITHUB_PROJECT/$GITHUB_PROJECT.php" >/dev/null
	zip --update "$GITHUB_PROJECT/$GITHUB_PROJECT.zip" "$GITHUB_PROJECT/$GITHUB_PROJECT.php" >/dev/null

	# Copy the plugin zip file to the working dir, in case manual upload to GitHub is necessary
	cd - >/dev/null
	cp $zip_file .
}

create_github_release() {
	tag="$VERSION-$SUFFIX"
	name="Version $tag. Not for production."
	body='This version is for internal testing. It should NOT be used for production.'

	echo
	echo "Creating test release '$tag'..."

	response_output=$(mktemp)

	http_code=$(curl --request POST \
		--header "Authorization: token $GITHUB_TOKEN" \
		--header 'Content-Type: application/json' \
		--data "{\"tag_name\":\"$tag\",\"target_commitish\":\"release/$VERSION\",\"name\":\"$name\",\"body\":\"$body\",\"prerelease\":true}" \
		--silent \
		--output "$response_output" \
		--write-out "%{http_code}" \
		https://api.github.com/repos/$GITHUB_ACCOUNT/$GITHUB_PROJECT/releases)

	response=$(cat "$response_output")
	rm "$response_output"

	if [[ ${http_code} -lt 200 || ${http_code} -gt 299 ]]; then
		echo "Could not create release:"
		echo "$response"
		abort
	fi

	echo
	echo "Uploading plugin zip package to the GitHub Release..."

	upload_url=$(echo $response | grep 'upload_url' | sed 's|.*"upload_url": "\([^{]*\).*|\1|')
	if [[ -z $upload_url ]]; then
		echo "No upload URL found in response:"
		echo "$response"
		abort
	fi

	response_output=$(mktemp)

	http_code=$(curl --request POST \
		--header "Authorization: token $GITHUB_TOKEN" \
		--header 'Content-Type: application/zip' \
		--data-binary @$GITHUB_PROJECT.zip \
		--silent \
		--output "$response_output" \
		--write-out "%{http_code}" \
		"$upload_url?name=$GITHUB_PROJECT.zip")

	response=$(cat "$response_output")
	rm "$response_output"

	if [[ ${http_code} -lt 200 || ${http_code} -gt 299 ]]; then
		echo "Could not upload plugin zip to GitHub release:"
		echo "$response"
		abort
	fi
}

# -----

# Check for 'git', 'svn, 'php' and 'Woorelease'
check_prerequisites

# Check if the 'release/VERSION' branch exists, and the next test SUFFIX to use (ex: 5.3.0-test3)
check_github_status

# Print the actions to perform
print_summary

echo
read -p "Do you want to continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
	abort
fi

# Create the remote 'release/VERSION' branch if necessary
if $CREATE_REMOTE_BRANCH; then
	create_git_branch
fi

# Run Woorelease, and update the 'Version' tag in the plugin headers to VERSION-SUFFIX (ex: 5.3.0 --> 5.3.0-test)
create_test_package

# Ask for the user GitHub token to create the release (if Woorelease was installed at the beginning no need to ask for it again)
if [ "$GITHUB_TOKEN" == '' ]; then
	echo
	read -p "To automatically create the release version in GitHub, paste your GitHub token: " -r
	if [[ -z "$REPLY" ]]; then
		echo
		echo "You need to manually create a release in GitHub:"
		echo "  - Go to: https://github.com/$GITHUB_ACCOUNT/$GITHUB_PROJECT/releases/new"
		echo "  - Fill the form with the following values:"
		echo "    Tag version   = $VERSION-$SUFFIX"
		echo "    Target        = release/$VERSION"
		echo "    Release title = Version $VERSION-$SUFFIX. Not for production."
		echo "    Description   = This version is for internal testing. It should NOT be used for production."
		echo "  - Attach the plugin zip file '$GITHUB_PROJECT.php'"
		echo "  - Select the checkbox 'This is a pre-release'"
		echo "  - Publish the release"
		echo
		echo "Partially completed, additional manual steps required."
		echo
		exit 0
	fi
	GITHUB_TOKEN=$REPLY
fi

# Create the release (and tag) in GitHub and upload the plugin zip file to it.
create_github_release

echo
echo "Completed."
echo
