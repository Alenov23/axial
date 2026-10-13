cmake_minimum_required(VERSION 3.29)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
  message(FATAL_ERROR "Use an out-of-source build, for example: cmake --preset native")
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum supported macOS")
set(AXIAL_VERSION "0.2.4" CACHE STRING "Product version; release CI supplies the tag version")
if(NOT AXIAL_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+$")
  message(FATAL_ERROR "AXIAL_VERSION must be MAJOR.MINOR.PATCH")
endif()
project(Axial VERSION ${AXIAL_VERSION} LANGUAGES C CXX OBJCXX)
if(NOT CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES "${CMAKE_HOST_SYSTEM_PROCESSOR}" CACHE STRING "Target CPU architectures" FORCE)
endif()
if(NOT APPLE)
  message(FATAL_ERROR "Axial requires macOS and Apple development tools")
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set_property(GLOBAL PROPERTY USE_FOLDERS ON)
include(CTest)
option(AXIAL_BUILD_APP "Build the Swift app, assets and app tests" ON)
option(AXIAL_SANITIZERS "Enable AddressSanitizer and UndefinedBehaviorSanitizer for native targets" OFF)
set(AXIAL_SIGN_IDENTITY "-" CACHE STRING "Code signing identity; - means local ad-hoc signing")
if(AXIAL_SANITIZERS AND AXIAL_BUILD_APP)
  message(FATAL_ERROR "Use the sanitizers preset (AXIAL_BUILD_APP=OFF) for native sanitizer tests")
endif()

add_library(axial-options INTERFACE)
target_include_directories(axial-options INTERFACE include third_party/freecad)
target_compile_options(axial-options INTERFACE
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall;-Wextra;-Wno-unused-parameter;-Wno-deprecated-declarations>"
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
if(AXIAL_SANITIZERS)
  target_compile_options(axial-options INTERFACE -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(axial-options INTERFACE -fsanitize=address,undefined)
endif()

include(cmake/WebDependencies.cmake)
add_library(axial-web STATIC src/web.mm)
target_link_libraries(axial-web PUBLIC axial-options axial-web-dependencies "-framework Foundation")
add_executable(axial-web-setup src/web_setup.mm)
target_link_libraries(axial-web-setup PRIVATE axial-options axial-web-dependencies "-framework Foundation" "-framework Security")
add_custom_command(TARGET axial-web-setup POST_BUILD
  COMMAND /usr/bin/codesign --force --options runtime --sign "${AXIAL_SIGN_IDENTITY}" $<TARGET_FILE:axial-web-setup> VERBATIM)
add_executable(axial-service src/service.mm)
target_link_libraries(axial-service PRIVATE axial-web)
target_link_libraries(axial-service PRIVATE axial-options "-framework AppKit" "-framework IOKit" "-framework ApplicationServices")
add_executable(axialctl src/ctl.cpp)
target_link_libraries(axialctl PRIVATE axial-options)
foreach(adapter IN ITEMS Client Navlib)
  if(adapter STREQUAL "Client")
    set(adapter_source src/connexion.mm)
    set(adapter_frameworks "-framework Foundation")
  else()
    set(adapter_source src/navlib.mm)
    set(adapter_frameworks "-framework AppKit" "-framework CoreVideo")
  endif()
  set(target "3Dconnexion${adapter}")
  add_library(${target} SHARED ${adapter_source})
  target_link_libraries(${target} PRIVATE axial-options ${adapter_frameworks})
  set_target_properties(${target} PROPERTIES FRAMEWORK TRUE FRAMEWORK_VERSION A
    MACOSX_FRAMEWORK_INFO_PLIST "${CMAKE_SOURCE_DIR}/app/Manifests/Framework.plist.in"
    MACOSX_FRAMEWORK_IDENTIFIER "pro.jest.${target}" VERSION 1.0.0 SOVERSION 1.0.0
    MACOSX_FRAMEWORK_BUNDLE_VERSION "1.0.0" MACOSX_FRAMEWORK_SHORT_VERSION_STRING "1.0.0"
    INSTALL_NAME_DIR /Library/Frameworks BUILD_WITH_INSTALL_NAME_DIR TRUE XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
  add_custom_command(TARGET ${target} POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -DFRAMEWORK=$<TARGET_BUNDLE_DIR:${target}>
      -DADAPTER=${adapter} -DSOURCE_DIR=${CMAKE_SOURCE_DIR} -DIDENTITY=${AXIAL_SIGN_IDENTITY}
      -P "${CMAKE_SOURCE_DIR}/cmake/Framework.cmake" VERBATIM)
endforeach()

if(AXIAL_BUILD_APP)
  file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/swift-cache")
  set(CMAKE_Swift_FLAGS "${CMAKE_Swift_FLAGS} -module-cache-path \"${CMAKE_BINARY_DIR}/swift-cache\"")
  enable_language(Swift)
  set(CMAKE_Swift_LANGUAGE_VERSION 5)
  set(CMAKE_Swift_COMPILATION_MODE wholemodule)
  include(cmake/Swift.cmake)
  add_library(axial-bridge STATIC app/bridge.cpp)
  # Swift-linked Xcode targets do not infer the C++ runtime from a static archive.
  target_link_libraries(axial-bridge PRIVATE axial-options PUBLIC c++)
  set(axial_app_sources
    app/Axial.swift app/AppLifecycle.swift app/AppInstance.swift app/AxisMeter.swift app/DeviceCatalog.swift
    app/Diagnostics.swift app/NativeControls.swift app/SceneTest.swift app/ServiceClient.swift
    app/ServiceLifecycle.swift app/SessionLog.swift app/TestModel.swift app/TestNavigation.swift app/WebSetup.swift
    app/ProfileModel.swift app/LiveView.swift app/MappingView.swift app/TuningView.swift app/ButtonsView.swift app/ProfilesView.swift app/SettingsView.swift)
  include(cmake/Resources.cmake)
  add_executable(Axial MACOSX_BUNDLE app/AxialApp.swift ${axial_app_sources} ${axial_resources})
  axial_swift_platform(Axial)
  target_compile_options(Axial PRIVATE -parse-as-library)
  target_link_libraries(Axial PRIVATE axial-bridge)
  set_target_properties(Axial PROPERTIES MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/app/Manifests/Axial.plist.in"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
  configure_file(app/Manifests/AxialService.plist.in "${CMAKE_BINARY_DIR}/generated/AxialService.plist" @ONLY)
  add_dependencies(Axial axial-assets axial-service axialctl axial-web-setup)
  set(bundle_command "${CMAKE_COMMAND}" -DAPP=$<TARGET_BUNDLE_DIR:Axial>
    -DSERVICE=$<TARGET_FILE:axial-service> -DCLI=$<TARGET_FILE:axialctl>
    -DGENERATED=${CMAKE_BINARY_DIR}/generated -DSOURCE_DIR=${CMAKE_SOURCE_DIR}
    -DBOOST_SOURCE=${axial_boost_SOURCE_DIR} -DTLS_SOURCE=${AXIAL_TLS_SOURCE}
    -DWEB_SETUP=$<TARGET_FILE:axial-web-setup>
    -DIDENTITY=${AXIAL_SIGN_IDENTITY} -P "${CMAKE_SOURCE_DIR}/cmake/Bundle.cmake")
  add_custom_command(TARGET Axial POST_BUILD COMMAND ${bundle_command} VERBATIM)
  # Refresh embedded helpers even when only the service/CLI was rebuilt.
  add_custom_target(axial-bundle ALL COMMAND ${bundle_command} DEPENDS Axial axial-service axialctl axial-web-setup VERBATIM)
endif()

include(cmake/Tests.cmake)
set(AXIAL_BENCH_SECONDS 60 CACHE STRING "Measurement seconds per benchmark load")
set(AXIAL_BENCH_RATE 1000 CACHE STRING "Mock input reports per second")
add_custom_target(benchmark
  COMMAND "${CMAKE_COMMAND}" -DBENCH=$<TARGET_FILE:axial-bench> -DSERVICE=$<TARGET_FILE:axial-service>
    -DCLIENT=$<TARGET_FILE:3DconnexionClient> -DSOURCE_DIR=${CMAKE_SOURCE_DIR}
    -DOUTPUT_DIR=${CMAKE_BINARY_DIR}/benchmarks -DSECONDS=${AXIAL_BENCH_SECONDS} -DRATE=${AXIAL_BENCH_RATE}
    -P "${CMAKE_SOURCE_DIR}/cmake/Benchmark.cmake"
  DEPENDS axial-bench axial-service 3DconnexionClient USES_TERMINAL VERBATIM)
if(AXIAL_BUILD_APP AND NOT AXIAL_SANITIZERS)
  install(SCRIPT cmake/CheckInstall.cmake COMPONENT Runtime)
  install(TARGETS Axial BUNDLE DESTINATION Applications COMPONENT Runtime)
  install(TARGETS 3DconnexionClient 3DconnexionNavlib FRAMEWORK DESTINATION Library/Frameworks COMPONENT Runtime)
  set(CPACK_GENERATOR productbuild)
  set(CPACK_PACKAGE_NAME Axial)
  set(CPACK_PACKAGE_VENDOR "Axial contributors")
  set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
  list(LENGTH CMAKE_OSX_ARCHITECTURES architecture_count)
  if(architecture_count GREATER 1)
    set(package_arch universal)
  else()
    set(package_arch "${CMAKE_OSX_ARCHITECTURES}")
  endif()
  set(CPACK_PACKAGE_FILE_NAME "Axial-${PROJECT_VERSION}-${package_arch}")
  set(CPACK_PACKAGE_DIRECTORY "${CMAKE_BINARY_DIR}/packages")
  set(CPACK_PACKAGING_INSTALL_PREFIX "/")
  set(CPACK_PRODUCTBUILD_IDENTIFIER "pro.jest.installer")
  set(CPACK_PRODUCTBUILD_DOMAINS TRUE)
  set(CPACK_PRODUCTBUILD_DOMAINS_ANYWHERE FALSE)
  set(CPACK_PRODUCTBUILD_DOMAINS_USER FALSE)
  set(CPACK_PRODUCTBUILD_DOMAINS_ROOT TRUE)
  set(CPACK_COMPONENTS_ALL Runtime)
  set(CPACK_COMPONENT_RUNTIME_DISPLAY_NAME "Axial")
  set(CPACK_COMPONENT_RUNTIME_DESCRIPTION "SpaceMouse service, settings app and compatibility frameworks")
  set(CPACK_COMPONENT_RUNTIME_REQUIRED TRUE)
  # pkgbuild's per-bundle relocation policy is independent of CPack's package
  # install prefix. Never update an app/framework found in a development tree.
  set(CPACK_COMPONENT_RUNTIME_PLIST "${CMAKE_SOURCE_DIR}/cmake/InstallerComponents.plist")
  file(READ "${CMAKE_SOURCE_DIR}/tools/install-guard.sh" install_guard)
  file(READ "${CMAKE_SOURCE_DIR}/tools/legacy-files.sh" legacy_files)
  string(REPLACE "source \"\$(dirname \"\${BASH_SOURCE[0]}\")/legacy-files.sh\"" "${legacy_files}" install_guard "${install_guard}")
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS tools/install-guard.sh tools/package-preinstall.sh tools/legacy-files.sh)
  file(READ "${CMAKE_SOURCE_DIR}/tools/package-preinstall.sh" package_preinstall)
  string(REPLACE "source \"\$(dirname \"$0\")/install-guard.sh\"" "${install_guard}" package_preinstall "${package_preinstall}")
  file(WRITE "${CMAKE_BINARY_DIR}/generated/preinstall" "${package_preinstall}")
  set(CPACK_PREFLIGHT_RUNTIME_SCRIPT "${CMAKE_BINARY_DIR}/generated/preinstall")
  # productbuild requires a supported extension for displayed installer resources.
  configure_file(LICENSE "${CMAKE_BINARY_DIR}/generated/License.txt" COPYONLY)
  set(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_BINARY_DIR}/generated/License.txt")
  set(CPACK_RESOURCE_FILE_WELCOME "${CMAKE_SOURCE_DIR}/cmake/InstallerWelcome.txt")
  set(CPACK_RESOURCE_FILE_README "${CMAKE_SOURCE_DIR}/cmake/InstallerWelcome.txt")
  set(CPACK_POST_BUILD_SCRIPTS "${CMAKE_SOURCE_DIR}/cmake/VerifyPackage.cmake")
  include(CPack)
endif()
