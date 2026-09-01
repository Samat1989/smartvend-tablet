cmake_minimum_required(VERSION 3.16)

# Версия уезжает в device_ping как p_app_version. Префикс `screen-` — это то,
# по чему панель отличает микромаркет с экраном от планшета (тот шлёт чистый
# semver), а поток OTA — от esp-relay и esp-pulse. Менять только вместе с
# docs/esp-screen-micromarket.md §5a.
set(PROJECT_VER "screen-0.1.0")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(esp-screen)
