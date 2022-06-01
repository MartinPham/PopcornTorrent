#!/bin/bash

LIBTORRENT_TARBALL="libtorrent.tar.gz"

DIR=`pwd` 
SRC_DIR="${DIR}/PopcornTorrent/Sources/torrent"
HEADERS_DIR="${DIR}/include/libtorrent"
BUILD_DIR="${DIR}/build_dependecies/torrent"

clean() {
	rm ${LIBTORRENT_TARBALL}
	rm -rf ${SRC_DIR}
	rm -rf ${BUILD_DIR}
}

download() {
	curl -L -o ${LIBTORRENT_TARBALL} \
		"https://github.com/arvidn/libtorrent/releases/download/v2.0.6/libtorrent-rasterbar-2.0.6.tar.gz"
}

extract() {
    rm -rf ${BUILD_DIR} && mkdir -p ${BUILD_DIR}
	rm -rf ${SRC_DIR}
    rm -rf ${HEADERS_DIR} && mkdir -p ${HEADERS_DIR}
	tar -xzf ${LIBTORRENT_TARBALL} --strip 1 -C ${BUILD_DIR}
    cp -r "${BUILD_DIR}/src" ${SRC_DIR}
    cp -r "${BUILD_DIR}/deps/try_signal/" "${SRC_DIR}/"
    cp -r "${BUILD_DIR}/include/libtorrent" "${DIR}/include"
}

clean
download
extract

echo "Done."
