vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO tintinhamans/GNS
    REF "fa5fd2dcb396510d3d3f56fac34b0f6410b57a8b"
    SHA512 fe023a7c41aa33cd272c62a925b6e5b1f61d92cf18d844a6d67f8bf4b0520b39e46019b5b63d81cd715344a8dfc6b3ce274f223fcbb8eb8a07f91da9858c7591
)

vcpkg_check_features(
    OUT_FEATURE_OPTIONS FEATURE_OPTIONS
    FEATURES
        ice             ENABLE_ICE
        webrtc          USE_STEAMWEBRTC
)

vcpkg_apply_patches(
    SOURCE_PATH "${SOURCE_PATH}"
    PATCHES
        "${CMAKE_CURRENT_LIST_DIR}/ios-ice-socket-null-guard.patch"
)

if("webrtc" IN_LIST FEATURES)
    vcpkg_from_git(
        OUT_SOURCE_PATH WEBRTC_SOURCE_PATH
        URL https://webrtc.googlesource.com/src
        REF 30a3e787948dd6cdd541773101d664b85eb332a6
    )
    file(REMOVE_RECURSE "${SOURCE_PATH}/src/external/webrtc")
    file(COPY "${WEBRTC_SOURCE_PATH}/." DESTINATION "${SOURCE_PATH}/src/external/webrtc")

    set(_steamwebrtc_cmakelists "${SOURCE_PATH}/src/external/steamwebrtc/CMakeLists.txt")
    file(READ "${_steamwebrtc_cmakelists}" _steamwebrtc_cmakelists_contents)
    string(REPLACE
        "#find_package(absl QUIET)\nset(absl_FOUND OFF)"
        "find_package(absl CONFIG REQUIRED)\nset(absl_FOUND ON)"
        _steamwebrtc_cmakelists_contents
        "${_steamwebrtc_cmakelists_contents}")
    file(WRITE "${_steamwebrtc_cmakelists}" "${_steamwebrtc_cmakelists_contents}")
endif()

if("${VCPKG_LIBRARY_LINKAGE}" STREQUAL "dynamic")
    set(BUILD_SHARED_LIB ON)
    set(BUILD_STATIC_LIB OFF)
else()
    set(BUILD_SHARED_LIB OFF)
    set(BUILD_STATIC_LIB ON)
endif()

if("${VCPKG_CRT_LINKAGE}" STREQUAL "static")
    set(MSVC_CRT_STATIC ON)
else()
    set(MSVC_CRT_STATIC OFF)
endif()

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DUSE_CRYPTO=OpenSSL
        -DBUILD_STATIC_LIB=${BUILD_STATIC_LIB}
        -DBUILD_SHARED_LIB=${BUILD_SHARED_LIB}
        -DMSVC_CRT_STATIC=${MSVC_CRT_STATIC}
        -DBUILD_TESTS=OFF
        -DBUILD_EXAMPLES=OFF
        -DBUILD_TOOLS=OFF
        ${FEATURE_OPTIONS}
    MAYBE_UNUSED_VARIABLES
        MSVC_CRT_STATIC
)

vcpkg_cmake_install()
vcpkg_cmake_config_fixup(CONFIG_PATH "lib/cmake/GameNetworkingSockets")
vcpkg_fixup_pkgconfig()

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/share")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")

vcpkg_copy_pdbs()
vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
