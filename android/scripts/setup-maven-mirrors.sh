#!/usr/bin/env bash
# =============================================================================
# setup-maven-mirrors.sh — Gradle init.d maven 镜像注入（出口带宽治理）
#
# 背景（2026-09-22 压测根因）：舰队出口 GA→香港晚高峰拥塞，
# repo.maven.apache.org / plugins.gradle.org / dl.google.com 的 HTTPS
# 流量会被掐断（Remote host terminated the handshake），Gradle 依赖解析挂死。
# 阿里云镜像域名（.aliyun.com）在 N150 squid 的 domestic_mirrors ACL 里
# always_direct 直连，流量不出境。
#
# 机制：生成 ~/.gradle/init.d/macrunara-maven-mirrors.gradle，
# 把阿里云镜像插到 buildscript / 项目 / pluginManagement 仓库首位，
# 并把 mavenCentral()/jcenter 实时改写为 aliyun public（原仓库保留兜底）。
#
# 开关：MACRUNARA_MAVEN_MIRROR=off 完全关闭（不生成 init 脚本）；
#       默认 cn。海外自建 runner 客户建议关闭。
# =============================================================================
set -euo pipefail

if [ "${MACRUNARA_MAVEN_MIRROR:-cn}" = "off" ]; then
  echo "==> maven mirrors disabled (MACRUNARA_MAVEN_MIRROR=off)"
  exit 0
fi

GRADLE_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
INIT_DIR="$GRADLE_HOME/init.d"
mkdir -p "$INIT_DIR"

cat > "$INIT_DIR/macrunara-maven-mirrors.gradle" <<'EOF'
// Macrunara CI maven 镜像注入（2026-09-22 出口带宽治理）。
// 阿里云镜像插到所有仓库容器首位，原仓库保留兜底；mavenCentral()/jcenter
// 原地改写为 aliyun public（改 url 不改集合，避免遍历期增删）。
// 关闭方式：外层 shell 见 MACRUNARA_MAVEN_MIRROR=off 时不生成本文件。
import org.gradle.api.artifacts.repositories.MavenArtifactRepository

def macrunaraMirrorUrls = [
  'gradle-plugin': 'https://maven.aliyun.com/repository/gradle-plugin',
  'google':        'https://maven.aliyun.com/repository/google',
  'central':       'https://maven.aliyun.com/repository/central',
  'public':        'https://maven.aliyun.com/repository/public',
]

// 镜像插到首位（clear + re-add 原仓库，保留其 credentials 等配置）
def macrunaraPrependMirrors
macrunaraPrependMirrors = { repos ->
  if (repos.findByName('macrunara-aliyun-public') != null) { return }
  def existing = new ArrayList(repos)
  repos.clear()
  macrunaraMirrorUrls.each { n, u ->
    repos.maven { r ->
      r.name = "macrunara-aliyun-${n}"
      r.url = u
    }
  }
  existing.each { repos.add(it) }
}

// 直连必撞拥塞出口的仓库：url 原地改写为 aliyun public。
// all{} 是活回调，项目脚本后加的 mavenCentral() 同样被改写。
def macrunaraRedirectCentral
macrunaraRedirectCentral = { repos ->
  repos.all { repo ->
    if (repo instanceof MavenArtifactRepository) {
      def u = repo.url.toString()
      if (u.startsWith('https://repo.maven.apache.org/maven2') ||
          u.startsWith('https://repo1.maven.org/maven2') ||
          u.startsWith('https://jcenter.bintray.com')) {
        repo.url = 'https://maven.aliyun.com/repository/public'
      }
    }
  }
}

// settings 的 plugins{} 块在 settings 脚本求值【期间】解析插件 classpath，
// settingsEvaluated 钩子太晚（求值后才触发）——必须用 beforeSettings。
gradle.beforeSettings { s ->
  macrunaraPrependMirrors(s.pluginManagement.repositories)
  macrunaraRedirectCentral(s.pluginManagement.repositories)
}

// dependencyResolutionManagement 在 settings 求值后才消费，settingsEvaluated 即可
gradle.settingsEvaluated { s ->
  try {
    macrunaraPrependMirrors(s.dependencyResolutionManagement.repositories)
    macrunaraRedirectCentral(s.dependencyResolutionManagement.repositories)
  } catch (Throwable ignored) {
    // Gradle < 6.8 无 dependencyResolutionManagement，忽略
  }
}

// 项目：buildscript（AGP/kotlin 插件）与常规依赖仓库。
// FAIL_ON_PROJECT_REPOS 模式下项目仓库不可配，捕获后跳过（settings 已覆盖）。
gradle.allprojects { p ->
  try {
    macrunaraPrependMirrors(p.buildscript.repositories)
    macrunaraRedirectCentral(p.buildscript.repositories)
    macrunaraPrependMirrors(p.repositories)
    macrunaraRedirectCentral(p.repositories)
  } catch (Throwable t) {
    p.logger.lifecycle("==> macrunara maven mirrors skipped for ${p.path}: ${t.message}")
  }
}

println '==> macrunara maven mirrors injected (aliyun first, originals as fallback)'
EOF

echo "==> maven mirrors -> aliyun ($INIT_DIR/macrunara-maven-mirrors.gradle)"
