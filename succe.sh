#!/bin/bash
set -e  # 遇到错误立即退出
set -o pipefail  # 管道命令出错也退出

# ===================== 配置项 ======================
LIBXSLT_VERSION="1.1.34"
LIBXSLT_RELEASE="14.el9_4"
WORK_DIR="$HOME/libxslt-build"
RPM_BUILD_DIR="$HOME/rpmbuild"
CVE_PATCHES=()
# ===================================================

# 颜色输出函数
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }

# 第一步：检查系统环境
check_env() {
    blue "===== 1. 检查系统环境 ====="
    if ! grep -q "release 9" /etc/redhat-release; then
        red "错误：当前系统不是 RHEL 9 系列！"
        exit 1
    fi
    green "✅ 系统环境验证通过（RHEL 9.7）"
    
    if grep -q "linuxkit" /proc/version; then
        yellow "⚠️  检测到容器环境，已自动适配！"
    fi
}

# 第二步：安装完整依赖
install_deps() {
    blue "===== 2. 安装编译依赖 ====="
    yellow "正在安装所有必要依赖..."
    dnf clean all || true
    dnf makecache || true
    # 补充所有缺失依赖
    dnf install -y rpm-build rpmdevtools gcc gcc-c++ make autoconf automake libtool \
        libxml2-devel zlib-devel libgcrypt-devel pkgconfig git wget tar xz \
        python3 libxslt procps-ng which patch || {
        red "❌ 依赖安装失败，请检查网络/权限！"
        exit 1
    }
    # 创建 python 软链接
    if [ ! -f /usr/bin/python ]; then
        ln -s /usr/bin/python3 /usr/bin/python
        green "✅ 已创建 python -> python3 软链接"
    fi
    green "✅ 依赖安装完成"
}

# 第三步：初始化 RPM 构建目录
init_rpm_dir() {
    blue "===== 3. 初始化 RPM 构建目录 ====="
    mkdir -p ${RPM_BUILD_DIR}/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
    green "✅ RPM 构建目录初始化完成：$RPM_BUILD_DIR"
}

# 第四步：直接下载官方源码包
fetch_source() {
    blue "===== 4. 下载 libxslt 官方源码包 ====="
    mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

    # 直接下载官方 1.1.34 源码包
    if [ ! -f "libxslt-${LIBXSLT_VERSION}.tar.xz" ]; then
        yellow "正在下载官方 libxslt-${LIBXSLT_VERSION} 源码包..."
        wget -q https://download.gnome.org/sources/libxslt/1.1/libxslt-${LIBXSLT_VERSION}.tar.xz -O libxslt-${LIBXSLT_VERSION}.tar.xz || {
            # 备用源
            wget -q https://ftp.acc.umu.se/pub/GNOME/sources/libxslt/1.1/libxslt-${LIBXSLT_VERSION}.tar.xz -O libxslt-${LIBXSLT_VERSION}.tar.xz || {
                red "❌ 源码包下载失败！请检查网络。"
                exit 1
            }
        }
    fi

    # 复制源码包到 RPM SOURCES 目录
    cp libxslt-${LIBXSLT_VERSION}.tar.xz "$RPM_BUILD_DIR/SOURCES/"
    if [ $? -eq 0 ]; then
        green "✅ 源码包已复制到：$RPM_BUILD_DIR/SOURCES/libxslt-${LIBXSLT_VERSION}.tar.xz"
    else
        red "❌ 源码包复制失败！文件路径：$WORK_DIR/libxslt-${LIBXSLT_VERSION}.tar.xz"
        exit 1
    fi

    # 可选：下载 CVE 补丁
    if [ ${#CVE_PATCHES[@]} -gt 0 ]; then
        blue "===== 5. 下载指定 CVE 补丁 ====="
        for commit in "${CVE_PATCHES[@]}"; do
            yellow "正在下载补丁（提交哈希：$commit）..."
            wget -q "https://github.com/GNOME/libxslt/commit/${commit}.patch" -O "$RPM_BUILD_DIR/SOURCES/CVE-${commit}.patch" || {
                red "❌ 补丁 $commit 下载失败！"
                exit 1
            }
        done
        green "✅ 指定 CVE 补丁下载完成"
    fi
}

# 第六步：生成 spec 文件（核心修复：补全 files 清单 + 过滤文档）
generate_spec() {
    blue "===== 6. 生成适配 RHEL 9.7 的 spec 文件 ====="
    cd "$RPM_BUILD_DIR/SPECS"

    # 写入 spec 文件
    cat > libxslt.spec << EOF
Name:           libxslt
Version:        ${LIBXSLT_VERSION}
Release:        ${LIBXSLT_RELEASE}
Summary:        XSLT library version 1 based on libxml2 (patched for RHEL 9.7)
License:        MIT
URL:            https://github.com/GNOME/libxslt
Source0:        %{name}-%{version}.tar.xz

# RHEL 9.7 编译依赖
BuildRequires:  gcc gcc-c++ make autoconf automake libtool
BuildRequires:  libxml2-devel >= 2.9.1
BuildRequires:  zlib-devel libgcrypt-devel pkgconfig
BuildRequires:  tar xz python3 libxslt procps-ng which patch

%description
Libxslt is the XSLT C library developed for the GNOME project.
This package contains the runtime libraries for libxslt (patched with latest security fixes for RHEL 9.7).

%prep
%setup -q

%build
# 直接执行 configure，添加 --without-docbook 彻底禁用文档生成
./configure --prefix=/usr --libdir=%{_libdir} --sysconfdir=/etc \
    --enable-shared --disable-static --build=x86_64-redhat-linux-gnu \
    --disable-docs --without-python --without-docbook
make %{?_smp_mflags}

%install
rm -rf %{buildroot}
make install DESTDIR=%{buildroot}
# 清理不必要的文件（避免打包冗余文件）
rm -f %{buildroot}%{_libdir}/*.la
rm -rf %{buildroot}%{_datadir}/doc/libxslt*  # 删除生成的 HTML 文档
rm -rf %{buildroot}%{_datadir}/aclocal       # 删除 m4 文件（非必需）
chmod -R 755 %{buildroot}%{_libdir}

%files
# 运行时库（核心）
%{_libdir}/libxslt.so.*
%{_libdir}/libexslt.so.*
# 可执行工具
%{_bindir}/xsltproc
%{_bindir}/xslt-config
# 头文件（开发依赖）
%{_includedir}/libexslt/*.h
%{_includedir}/libxslt/*.h
# 库文件（动态链接）
%{_libdir}/libexslt.so
%{_libdir}/libxslt.so
# pkgconfig 配置
%{_libdir}/pkgconfig/libexslt.pc
%{_libdir}/pkgconfig/libxslt.pc
# 配置脚本
%{_libdir}/xsltConf.sh
# 手册页
%{_mandir}/man1/xsltproc.1*
%{_mandir}/man3/libexslt.3*
%{_mandir}/man3/libxslt.3*
# 许可证和文档
%license COPYING
%doc AUTHORS README NEWS

%post -p /sbin/ldconfig
%postun -p /sbin/ldconfig
EOF

    # 添加 CVE 补丁
    if [ ${#CVE_PATCHES[@]} -gt 0 ]; then
        patch_num=100
        for commit in "${CVE_PATCHES[@]}"; do
            sed -i "/Source0/a Patch${patch_num}: CVE-${commit}.patch" libxslt.spec
            ((patch_num++))
        done
        patch_num=100
        for commit in "${CVE_PATCHES[@]}"; do
            sed -i "/%prep/a %patch${patch_num} -p1" libxslt.spec
            ((patch_num++))
        done
    fi

    green "✅ spec 文件生成完成：$RPM_BUILD_DIR/SPECS/libxslt.spec"
}

# 第七步：编译生成 RPM 包
build_rpm() {
    blue "===== 7. 编译生成 RPM 包 ====="
    cd "$RPM_BUILD_DIR/SPECS"
    yellow "正在编译 RPM 包（预计 3-8 分钟）..."
    # 禁用 debug，加快编译
    rpmbuild -bb --without debug libxslt.spec || {
        red "❌ RPM 编译失败！请查看上述错误日志。"
        exit 1
    }
    # 查找 RPM 包
    RPM_FILE=$(find "$RPM_BUILD_DIR/RPMS" -name "libxslt-${LIBXSLT_VERSION}-${LIBXSLT_RELEASE}*.rpm" | head -1)
    if [ -z "$RPM_FILE" ]; then
        red "❌ 未找到生成的 RPM 包！"
        exit 1
    fi
    green "✅ RPM 包编译完成！文件路径："
    echo "   $RPM_FILE"
}

# 第八步：清理临时文件
cleanup() {
    blue "===== 8. 清理临时文件 ====="
    rm -rf "$WORK_DIR"
    yellow "✅ 临时文件已清理：$WORK_DIR"
}

# 主流程
main() {
    clear
    green "========================================"
    green "  libxslt RPM 包一键编译脚本（RHEL 9.7）"
    green "  版本：${LIBXSLT_VERSION}-${LIBXSLT_RELEASE}"
    green "========================================"
    echo ""

    check_env
    install_deps
    init_rpm_dir
    fetch_source
    generate_spec
    build_rpm
    cleanup

    echo ""
    green "🎉 全部操作完成！"
    yellow "👉 安装命令：dnf install -y $RPM_FILE --force"
    yellow "👉 验证版本：rpm -q libxslt"
    echo ""
}

# 启动主流程
main
