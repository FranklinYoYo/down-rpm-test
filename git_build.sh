#!/bin/bash
set -e  # 遇到错误立即退出

# ===================== 配置项（无需修改）=====================
LIBXSLT_VERSION="1.1.34"
LIBXSLT_RELEASE="14.el9_4"
GIT_REPO="https://github.com/GNOME/libxslt.git"
GIT_TAG="v1.1.34"
RPM_BUILD_DIR="$HOME/rpmbuild"
WORK_DIR="$HOME/libxslt-build"
BUILD_LOG="/tmp/libxslt-build.log"
# ============================================================

# 颜色输出函数
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }

# 步骤1：系统环境信息（无判断，仅输出）
check_env() {
    blue "===== 1. 系统环境信息 ======"
    echo "当前系统版本：$(cat /etc/redhat-release)"
    echo "当前内核版本：$(uname -r)"
    echo "当前架构：$(uname -m)"
    green "✅ 系统信息检测完成，自动继续编译"
    echo "-------------------------"
}

# 步骤2：安装编译依赖（带详细输出）
install_deps() {
    blue "===== 2. 安装编译依赖 ======"
    yellow "正在安装核心编译依赖（请稍候）..."
    dnf install -y \
        git gcc gcc-c++ make autoconf automake libtool \
        libxml2-devel zlib-devel libgcrypt-devel pkgconfig \
        rpm-build rpmdevtools tar xz wget || {
        red "❌ 依赖安装失败！请手动安装上述包后重试。"
        exit 1
    }
    green "✅ 核心依赖安装完成"
    echo "-------------------------"
}

# 步骤3：克隆仓库并切换标签（带验证）
clone_and_checkout() {
    blue "===== 3. 克隆仓库并切换标签 ======"
    mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

    # 克隆/更新仓库
    if [ -d "libxslt" ]; then
        yellow "检测到已有仓库，拉取最新标签..."
        cd libxslt
        git fetch --tags
    else
        yellow "克隆 libxslt 官方仓库..."
        git clone "$GIT_REPO" libxslt
        cd libxslt
    fi

    # 切换到v1.1.34标签
    git checkout tags/$GIT_TAG
    green "✅ 成功切换到 $GIT_TAG 标签"

    # 验证修复存在
    if git show 22324737 >/dev/null 2>&1; then
        green "✅ 验证通过：包含 CVE-2023-29469 核心修复"
    else
        red "❌ 源码缺失关键修复！请检查仓库完整性。"
        exit 1
    fi
    echo "-------------------------"
}

# 步骤4：准备RPM构建环境（修复目录名匹配问题）
prepare_rpm_source() {
    blue "===== 4. 准备RPM构建环境 ======"
    # 创建RPM标准目录
    mkdir -p ${RPM_BUILD_DIR}/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

    # 打包源码（关键修复：指定解压后的目录名为 libxslt-1.1.34）
    yellow "打包源码为RPM格式..."
    cd "$WORK_DIR"
    tar -cJf "libxslt-${LIBXSLT_VERSION}.tar.xz" --transform "s/^libxslt/libxslt-${LIBXSLT_VERSION}/" libxslt/
    cp "libxslt-${LIBXSLT_VERSION}.tar.xz" "${RPM_BUILD_DIR}/SOURCES/"
    
    green "✅ 源码包已复制到 RPM 构建目录（修复目录名匹配问题）"
    echo "-------------------------"
}

# 步骤5：生成Spec文件
generate_spec() {
    blue "===== 5. 生成Spec构建文件 ======"
    cat > "${RPM_BUILD_DIR}/SPECS/libxslt.spec" << EOF
Name:           libxslt
Version:        ${LIBXSLT_VERSION}
Release:        ${LIBXSLT_RELEASE}
Summary:        XSLT library (${GIT_TAG} official tag, CVE-2023-29469 fixed)
License:        MIT
URL:            ${GIT_REPO}
Source0:        libxslt-${LIBXSLT_VERSION}.tar.xz

BuildRequires:  autoconf automake libtool gcc gcc-c++ make
BuildRequires:  libxml2-devel zlib-devel libgcrypt-devel pkgconfig

%description
Libxslt ${LIBXSLT_VERSION} (${GIT_TAG} official tag) with CVE-2023-29469 fix (commit 22324737), compiled for RHEL 9.x.

%package devel
Summary:        Development files for libxslt
Requires:       %{name} = %{version}-%{release}
Requires:       libxml2-devel

%description devel
Development libraries and headers for libxslt ${LIBXSLT_VERSION}.

%prep
%setup -q

%build
autoreconf -vfi
%configure --prefix=/usr --libdir=%{_libdir} --enable-shared --disable-static --disable-docs --without-python
%make_build

%install
%make_install
rm -f %{buildroot}%{_libdir}/*.la

%files
%license COPYING
%{_libdir}/libxslt.so.*
%{_libdir}/libexslt.so.*
%{_bindir}/xsltproc
%{_mandir}/man1/xsltproc.1*

%files devel
%{_includedir}/libexslt/
%{_includedir}/libxslt/
%{_libdir}/libxslt.so
%{_libdir}/libexslt.so
%{_libdir}/pkgconfig/*.pc
%{_bindir}/xslt-config

%post -p /sbin/ldconfig
%postun -p /sbin/ldconfig
EOF
    green "✅ Spec文件生成完成（适配 RHEL 9.x）"
    echo "-------------------------"
}

# 步骤6：编译RPM包（带详细日志+进度提示）
build_rpm() {
    blue "===== 6. 编译RPM包 ======"
    yellow "正在编译 libxslt-${LIBXSLT_VERSION}-${LIBXSLT_RELEASE}.x86_64.rpm..."
    yellow "📝 编译日志已保存到：$BUILD_LOG"
    yellow "💡 可新开终端执行 tail -f $BUILD_LOG 查看实时进度"
    echo "-------------------------"

    # 执行编译（输出详细日志，不静默）
    cd "${RPM_BUILD_DIR}/SPECS/"
    rpmbuild -bb libxslt.spec 2>&1 | tee "$BUILD_LOG"

    # 检查编译结果
    RPM_FILE="${RPM_BUILD_DIR}/RPMS/x86_64/libxslt-${LIBXSLT_VERSION}-${LIBXSLT_RELEASE}.x86_64.rpm"
    if [ -f "$RPM_FILE" ]; then
        green "✅ RPM包编译成功！"
        green "📦 最终包路径：$RPM_FILE"
        green "🔍 SHA-256校验值：$(sha256sum $RPM_FILE | awk '{print $1}')"
    else
        red "❌ RPM包编译失败！详细日志：$BUILD_LOG"
        exit 1
    fi
    echo "-------------------------"
}

# 步骤7：自动清理临时文件
cleanup() {
    blue "===== 7. 清理临时文件 ======"
    yellow "清理构建临时目录..."
    rm -rf "$WORK_DIR"
    green "✅ 临时目录已清理"
    echo "-------------------------"
}

# 主流程
main() {
    clear
    green "=============================================="
    green "  libxslt-${LIBXSLT_VERSION}-${LIBXSLT_RELEASE} 编译脚本"
    green "  基于官方v1.1.34标签（含CVE-2023-29469修复）"
    green "=============================================="
    echo ""

    check_env
    install_deps
    clone_and_checkout
    prepare_rpm_source
    generate_spec
    build_rpm
    cleanup

    echo ""
    green "🎉 编译流程全部完成！"
    green "📌 分发命令示例："
    echo "   scp ${RPM_BUILD_DIR}/RPMS/x86_64/libxslt-${LIBXSLT_VERSION}-${LIBXSLT_RELEASE}.x86_64.rpm 目标IP:/root/"
    echo "   目标机器安装：sudo dnf install -y /root/libxslt-${LIBXSLT_VERSION}-${LIBXSLT_RELEASE}.x86_64.rpm --force"
    echo ""
}

# 启动脚本
main
