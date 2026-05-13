#! /usr/bin/env bash

if [[ ! -d "$1" ]] || [[ -z "$2" ]]
then
    echo "usage: ${0} input_dir output_dir"
    exit 1
fi

# Sorry son, we have Hakyll at home
copy_files() {
    local src="${1:-.}"
    local dst="$2"
    for file in "${src}"/*
    do
        # Remove the first directory, which is our source
        local stripped="${file#*/}"
        local out="${dst}/${stripped}"
        if [[ -d "${file}" ]]
        then
            copy_files "${file}" "${dst}"
        elif [[ "${file##*.}" == "md" ]]
        then
            # Strip filename and add html ext
            local html_out="${out%.*}.html"
            echo "compiling markdown from ${file} to ${html_out}"
            # Make parent dir
            mkdir -p "${html_out%/*}"
            pandoc -s -f markdown+fenced_divs --highlight-style haddock --embed-resources --standalone --css pandoc.css "${file}" -o "${html_out}"
        else 
            echo "copying ${file} to ${out}"
            rsync -a --mkpath "${file}" "${dst}/${stripped}"
        fi
    done
}

copy_files "$1" "$2"
