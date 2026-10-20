include $(TOPDIR)/rules.mk

PKG_NAME:=proton2025-expanded-daemon
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=GPLv3
PKG_MAINTAINER:=Elux414

include $(INCLUDE_DIR)/package.mk

define Package/proton2025-expanded-daemon
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Proton2025 expanded monitoring daemon
  DEPENDS:=+ucode +ucode-mod-ubus +ucode-mod-uci +ucode-mod-uloop
endef

define Package/proton2025-expanded-daemon/description
 Background monitoring daemon for Proton2025 expanded theme.
 Collects service status history, runs L7 health checks,
 and writes events to /tmp/proton-services-history/.
endef

# Ключевая строка: говорим системе, что компиляции нет
define Build/Compile
endef

define Package/proton2025-expanded-daemon/install
	$(INSTALL_DIR) $(1)/usr/share/proton2025
	$(INSTALL_BIN) ./src/proton2025-daemon.uc $(1)/usr/share/proton2025/daemon.uc
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/proton2025-expanded-daemon $(1)/etc/init.d/proton2025-expanded-daemon
endef

$(eval $(call BuildPackage,proton2025-expanded-daemon))
