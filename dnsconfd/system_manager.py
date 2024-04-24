import logging as lgr
import os
import os.path
import shutil


class SystemManager:
    HEADER = "# Generated by dnsconfd\n"

    def __init__(self, config: dict):
        """ Maintain /etc/resolv.conf including backups

        :param config: Dict containing configuration of Dnsconfd
        :type config: dict
        """
        # File contents
        self._backup = None
        # Original symlink destination
        self._backup_link = None
        self._resolv_conf_path = config["resolv_conf_path"]
        self._listen_address = config["listen_address"]
        self._resolver_options = config["resolver_options"]

    def set_resolvconf(self) -> bool:
        """ Replace resolv.conf content with our config and perform backup

        :return: True if operation was successful, otherwise False
        :rtype: bool
        """
        try:
            if os.path.islink(self._resolv_conf_path):
                self._backup_link = os.readlink(self._resolv_conf_path)
                lgr.debug(f"Resolvconf is symlink to {self._backup_link}")
                os.unlink(self._resolv_conf_path)
            else:
                lgr.debug("Resolvconf is plain file")
                with open(self._resolv_conf_path, "r") as orig_resolv:
                    self._backup = orig_resolv.read()
        except FileNotFoundError as e:
            lgr.error(f"Not present resolvconf: {e}")
            return False
        except OSError as e:
            lgr.error(f"OSError encountered while reading resolv.conf {e}")
            return False

        try:
            with open(self._resolv_conf_path, "w") as new_resolv:
                new_resolv.write(self._get_resolvconf_string())
        except OSError as e:
            lgr.error(f"OSError encountered while writing resolv.conf: {e}")
            return False
        return True

    def _get_resolvconf_string(self, search_domains=None):
        if search_domains is None:
            search_domains = []
        conf = self.HEADER
        if self._resolver_options:
            conf += f"options {self._resolver_options}\n"
        conf += f"nameserver {self._listen_address}\n"
        if len(search_domains):
            conf += f"search {' '.join(search_domains)}\n"
        return conf

    def revert_resolvconf(self) -> bool:
        """ Return resolv.conf to its original state

        :return: True if operation was successful, otherwise False
        :rtype: bool
        """
        if self._backup is not None:
            try:
                with open(self._resolv_conf_path, "w") as new_resolv:
                    new_resolv.write(self._backup)
            except OSError as e:
                lgr.error(f"OSError encountered while writing resolv.conf {e}")
                return False
        elif self._backup_link is not None:
            try:
                os.unlink(self._resolv_conf_path)
                os.symlink(self._backup_link, self._resolv_conf_path)
            except OSError as e:
                lgr.error("OSError encountered while linking "
                          + f"back resolv.conf: {e}")
                return False

    def update_resolvconf(self, search_domains: list[str]) -> bool:
        """ Insert search domains into resolv.conf

        :param search_domains: Domains for insertion
        :type search_domains: list[str]
        :return: True if operation was successful, otherwise False
        :rtype: bool
        """
        lgr.debug(f"Updating resolvconf with domains {search_domains}")
        try:
            with open(self._resolv_conf_path, "w") as new_resolv:
                new_resolv.write(self._get_resolvconf_string(search_domains))
        except OSError as e:
            lgr.error(f"OSError encountered while writing resolv.conf: {e}")
            return False
        return True

    def chown_resolvconf(self, user: str) -> bool:
        try:
            if os.path.islink(self._resolv_conf_path):
                os.unlink(self._resolv_conf_path)
            open(self._resolv_conf_path, 'w+').close()
            shutil.chown(self._resolv_conf_path, user, None)
        except OSError as e:
            lgr.error(f"Failed to change ownership of resolv.conf: {e}")
            return False
        return True
