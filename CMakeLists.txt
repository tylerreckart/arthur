cmake_minimum_required(VERSION 3.20)
project(intercom VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(FetchContent)

FetchContent_Declare(
  json
  GIT_REPOSITORY https://github.com/nlohmann/json.git
  GIT_TAG v3.11.3
  GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(json)

FetchContent_Declare(
  httplib
  GIT_REPOSITORY https://github.com/yhirose/cpp-httplib.git
  GIT_TAG v0.18.3
  GIT_SHALLOW TRUE
)
set(HTTPLIB_INSTALL OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(httplib)

find_package(OpenSSL REQUIRED)
find_package(SQLite3 REQUIRED)
find_package(Threads REQUIRED)
if(TARGET SQLite::SQLite3 AND NOT TARGET SQLite3::SQLite3)
  add_library(SQLite3::SQLite3 ALIAS SQLite::SQLite3)
endif()

add_executable(intercom
  src/main.cpp
  src/config.cpp
  src/stt_whisper.cpp
  src/tts_kokoro.cpp
  src/audio_dsp.cpp
  src/speech_delivery.cpp
  src/arbiter_client.cpp
  src/filler_client.cpp
  src/session_store.cpp
  src/fast_path.cpp
  src/home_intent.cpp
  src/home_client.cpp
  src/surface.cpp
  src/weather_client.cpp
  src/clock.cpp
  src/turn_pipeline.cpp
  src/http_server.cpp
  src/ws.cpp
  src/util.cpp
  src/speakable.cpp
  src/managed_server.cpp
  src/device_hub.cpp
  src/speakback.cpp
)

target_include_directories(intercom PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(intercom PRIVATE
  nlohmann_json::nlohmann_json
  httplib::httplib
  OpenSSL::SSL
  OpenSSL::Crypto
  SQLite::SQLite3
  Threads::Threads
)

target_compile_definitions(intercom PRIVATE
  "INTERCOM_SCRIPTS_DIR=\"${CMAKE_SOURCE_DIR}/scripts\""
  CPPHTTPLIB_OPENSSL_SUPPORT
)
if(APPLE)
  target_compile_definitions(intercom PRIVATE CPPHTTPLIB_USE_POLL)
endif()

install(TARGETS intercom RUNTIME DESTINATION bin)
install(FILES config/intercom.example.json config/arthur.agent.json DESTINATION share/intercom)
install(FILES scripts/kokoro_server.py scripts/voice_audition.py DESTINATION share/intercom)

enable_testing()

add_executable(test_flush_sentences
  tests/test_flush_sentences.cpp
  src/util.cpp
)
target_include_directories(test_flush_sentences PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
add_test(NAME test_flush_sentences COMMAND test_flush_sentences)

add_executable(test_speech_join
  tests/test_speech_join.cpp
)
add_test(NAME test_speech_join COMMAND test_speech_join)

add_executable(test_wav_util
  tests/test_wav_util.cpp
  src/util.cpp
)
target_include_directories(test_wav_util PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
add_test(NAME test_wav_util COMMAND test_wav_util)

add_executable(test_speakable
  tests/test_speakable.cpp
  src/speakable.cpp
)
target_include_directories(test_speakable PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
add_test(NAME test_speakable COMMAND test_speakable)

add_executable(test_speech_dsp
  tests/test_speech_dsp.cpp
  src/audio_dsp.cpp
  src/speech_delivery.cpp
  src/util.cpp
)
target_include_directories(test_speech_dsp PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
add_test(NAME test_speech_dsp COMMAND test_speech_dsp)

add_executable(test_fast_path
  tests/test_fast_path.cpp
  src/fast_path.cpp
  src/home_intent.cpp
  src/home_client.cpp
  src/surface.cpp
  src/weather_client.cpp
  src/clock.cpp
  src/util.cpp
)
target_include_directories(test_fast_path PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_link_libraries(test_fast_path PRIVATE
  nlohmann_json::nlohmann_json
  httplib::httplib
  OpenSSL::SSL
  OpenSSL::Crypto
  Threads::Threads
)
target_compile_definitions(test_fast_path PRIVATE CPPHTTPLIB_OPENSSL_SUPPORT)
if(APPLE)
  target_compile_definitions(test_fast_path PRIVATE CPPHTTPLIB_USE_POLL)
endif()
add_test(NAME test_fast_path COMMAND test_fast_path)

add_executable(test_home_intent
  tests/test_home_intent.cpp
  src/home_intent.cpp
  src/util.cpp
)
target_include_directories(test_home_intent PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
add_test(NAME test_home_intent COMMAND test_home_intent)

add_executable(test_surface
  tests/test_surface.cpp
  src/surface.cpp
  src/weather_client.cpp
  src/home_intent.cpp
  src/util.cpp
)
target_include_directories(test_surface PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_link_libraries(test_surface PRIVATE
  nlohmann_json::nlohmann_json
  httplib::httplib
  OpenSSL::SSL
  OpenSSL::Crypto
  Threads::Threads
)
target_compile_definitions(test_surface PRIVATE CPPHTTPLIB_OPENSSL_SUPPORT)
add_test(NAME test_surface COMMAND test_surface)

add_executable(test_sentence_tts
  tests/test_sentence_tts.cpp
  src/turn_pipeline.cpp
  src/speakable.cpp
  src/util.cpp
  src/session_store.cpp
  src/fast_path.cpp
  src/home_intent.cpp
  src/home_client.cpp
  src/surface.cpp
  src/weather_client.cpp
  src/clock.cpp
  src/arbiter_client.cpp
  src/filler_client.cpp
)
target_include_directories(test_sentence_tts PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_link_libraries(test_sentence_tts PRIVATE
  nlohmann_json::nlohmann_json
  httplib::httplib
  OpenSSL::SSL
  OpenSSL::Crypto
  SQLite::SQLite3
  Threads::Threads
)
target_compile_definitions(test_sentence_tts PRIVATE CPPHTTPLIB_OPENSSL_SUPPORT)
if(APPLE)
  target_compile_definitions(test_sentence_tts PRIVATE CPPHTTPLIB_USE_POLL)
endif()
add_test(NAME test_sentence_tts COMMAND test_sentence_tts)

add_executable(test_ws_stream
  tests/test_ws_stream.cpp
  src/ws.cpp
  src/config.cpp
  src/turn_pipeline.cpp
  src/speakable.cpp
  src/util.cpp
  src/session_store.cpp
  src/fast_path.cpp
  src/home_intent.cpp
  src/home_client.cpp
  src/surface.cpp
  src/weather_client.cpp
  src/clock.cpp
  src/arbiter_client.cpp
  src/filler_client.cpp
  src/device_hub.cpp
)
target_include_directories(test_ws_stream PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_link_libraries(test_ws_stream PRIVATE
  nlohmann_json::nlohmann_json
  httplib::httplib
  OpenSSL::SSL
  OpenSSL::Crypto
  SQLite3::SQLite3
  Threads::Threads
)
target_compile_definitions(test_ws_stream PRIVATE CPPHTTPLIB_OPENSSL_SUPPORT)
if(APPLE)
  target_compile_definitions(test_ws_stream PRIVATE CPPHTTPLIB_USE_POLL)
endif()
add_test(NAME test_ws_stream COMMAND test_ws_stream)

add_executable(test_speakback
  tests/test_speakback.cpp
  src/speakback.cpp
  src/device_hub.cpp
  src/arbiter_client.cpp
  src/session_store.cpp
  src/util.cpp
  src/speakable.cpp
  src/clock.cpp
  src/ws.cpp
  src/config.cpp
  src/turn_pipeline.cpp
  src/fast_path.cpp
  src/home_intent.cpp
  src/home_client.cpp
  src/surface.cpp
  src/weather_client.cpp
  src/filler_client.cpp
)
target_include_directories(test_speakback PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_link_libraries(test_speakback PRIVATE
  nlohmann_json::nlohmann_json
  httplib::httplib
  OpenSSL::SSL
  OpenSSL::Crypto
  SQLite3::SQLite3
  Threads::Threads
)
target_compile_definitions(test_speakback PRIVATE CPPHTTPLIB_OPENSSL_SUPPORT)
if(APPLE)
  target_compile_definitions(test_speakback PRIVATE CPPHTTPLIB_USE_POLL)
endif()
add_test(NAME test_speakback COMMAND test_speakback)

find_program(Python3_EXECUTABLE NAMES python3 python)
if(Python3_EXECUTABLE)
  add_test(
    NAME test_kokoro_voice
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tests/test_kokoro_voice.py
  )
endif()

