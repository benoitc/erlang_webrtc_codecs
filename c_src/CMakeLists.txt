# Builds one NIF per codec library found on this machine, into ../priv.
#
# A library that is missing only leaves its codec out: the Erlang module
# of that codec then reports no codec (webrtc_codecs:available/0). Each
# library is looked up with pkg-config; -DWEBRTC_CODECS_REQUIRE="opus;..."
# turns a missing one into an error, for builds that must have it.
cmake_minimum_required(VERSION 3.16)
project(webrtc_codecs_nifs C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_program(ERL_EXECUTABLE erl)
if(NOT ERL_EXECUTABLE)
  message(FATAL_ERROR "erl not found")
endif()

execute_process(
  COMMAND ${ERL_EXECUTABLE} -noshell -boot no_dot_erlang -eval
    "io:format(\"~ts/erts-~ts/include\", [code:root_dir(), erlang:system_info(version)]), halt()."
  OUTPUT_VARIABLE ERTS_INCLUDE_DIR
  ERROR_QUIET
  OUTPUT_STRIP_TRAILING_WHITESPACE)

if(NOT EXISTS "${ERTS_INCLUDE_DIR}/erl_nif.h")
  message(FATAL_ERROR "erl_nif.h not found under ${ERTS_INCLUDE_DIR}")
endif()

find_package(PkgConfig REQUIRED)

set(WEBRTC_CODECS_REQUIRE "" CACHE STRING "Codec libraries that must be found")

# add_codec_nif(<nif name> <pkg-config module> <sources...>)
function(add_codec_nif NAME PKG)
  pkg_check_modules(${NAME}_DEP IMPORTED_TARGET ${PKG})
  if(NOT ${NAME}_DEP_FOUND)
    if("${PKG}" IN_LIST WEBRTC_CODECS_REQUIRE)
      message(FATAL_ERROR "${PKG} is required but pkg-config does not find it")
    endif()
    message(STATUS "webrtc_codecs: ${PKG} not found, ${NAME} is not built")
    # A NIF from an earlier build would load against a library that is gone.
    file(REMOVE "${CMAKE_CURRENT_SOURCE_DIR}/../priv/${NAME}.so")
    return()
  endif()
  message(STATUS "webrtc_codecs: ${NAME} with ${PKG} ${${NAME}_DEP_VERSION}")

  # MODULE, not SHARED: a NIF is dlopen'd, never linked against, and on
  # macOS MODULE gives a bundle rather than a dylib. erlang:load_nif/2
  # appends ".so" on every platform, macOS included, so pin the suffix.
  add_library(${NAME} MODULE ${ARGN})
  set_target_properties(${NAME} PROPERTIES
    PREFIX ""
    SUFFIX ".so"
    POSITION_INDEPENDENT_CODE ON
    C_VISIBILITY_PRESET hidden
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../priv")
  target_include_directories(${NAME} PRIVATE "${ERTS_INCLUDE_DIR}")
  target_link_libraries(${NAME} PRIVATE PkgConfig::${NAME}_DEP)
  target_compile_options(${NAME} PRIVATE -Wall -Wextra)

  # The enif_* symbols are resolved by the emulator at load time, so the
  # link must tolerate them being undefined. ELF does by default; Mach-O
  # needs telling.
  if(APPLE)
    target_link_options(${NAME} PRIVATE -undefined dynamic_lookup)
  endif()
endfunction()

add_codec_nif(webrtc_codecs_opus_nif opus webrtc_codecs_opus_nif.c)
add_codec_nif(webrtc_codecs_vpx_nif vpx webrtc_codecs_vpx_nif.c)
