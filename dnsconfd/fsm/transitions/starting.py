from dnsconfd.dns_managers import UnboundManager
from dnsconfd.fsm import ContextEvent, ExitCode, ContextState
from dnsconfd.fsm.transitions import TransitionImplementations

from gi.repository import GLib


class Starting(TransitionImplementations):

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.transitions = {
            ContextState.STARTING: {
                "KICKOFF": (ContextState.CONFIGURING_DNS_MANAGER,
                            self._starting_kickoff_transition),
                "UPDATE": (ContextState.STARTING,
                           self._update_transition)
            },
            ContextState.CONFIGURING_DNS_MANAGER: {
                "SUCCESS": (ContextState.CONNECTING_DBUS,
                            self._conf_dns_mgr_success_transition)
            },
            ContextState.CONNECTING_DBUS: {
                "SUCCESS": (ContextState.SUBMITTING_START_JOB,
                            self._connecting_dbus_success_transition)
            },
            ContextState.SUBMITTING_START_JOB: {
                "SUCCESS": (ContextState.WAITING_FOR_START_JOB,
                            lambda y: None)
            },
            ContextState.WAITING_FOR_START_JOB: {
                "START_OK": (ContextState.POLLING,
                             self._job_finished_success_transition),
                "UPDATE": (ContextState.WAITING_FOR_START_JOB,
                           self._update_transition)
            },
            ContextState.POLLING: {
                "TIMER_UP": (ContextState.POLLING,
                             self._polling_timer_up_transition),
                "UPDATE": (ContextState.POLLING,
                           self._update_transition)
            },
            ContextState.WAITING_RESTART_JOB: {
                "RESTART_SUCCESS": (ContextState.POLLING,
                                    self._job_finished_success_transition),
                "UPDATE": (ContextState.WAITING_RESTART_JOB,
                           self._update_transition)
            },
        }

    def _starting_kickoff_transition(self, event: ContextEvent):
        """ Transition to CONNECTING_DBUS

        Attempt to connect to DBUS and subscribe to systemd signals

        :param event: not used
        :type event: ContextEvent
        :return: Success or FAIL with exit code
        :rtype: ContextEvent | None
        """

        self.container.dns_mgr = UnboundManager()
        address = self.container.config["listen_address"]
        dnssec = self.container.config["dnssec_enabled"]
        if self.container.dns_mgr.configure(address, dnssec):
            self.lgr.info("Successfully configured DNS manager")
            return ContextEvent("SUCCESS")

        self.lgr.error("Unable to configure DNS manager")
        self.container.set_exit_code(ExitCode.CONFIG_FAILURE)
        return ContextEvent("FAIL")

    def _conf_dns_mgr_success_transition(self, event: ContextEvent) \
            -> ContextEvent | None:
        """ Transition to CONNECTING_DBUS

        Attempt to configure dns manager and its files

        :param event: not used
        :type: event: ContextEvent
        :return: SUCCESS or FAIL with exit code
        :rtype: ContextEvent | None
        """

        if (not self.container.connect_systemd()
                or not self.container.subscribe_systemd_signals()):
            self.lgr.error("Failed to connect to systemd through DBUS")
            self.container.set_exit_code(ExitCode.DBUS_FAILURE)
            return ContextEvent("FAIL")
        else:
            self.lgr.info("Successfully connected to systemd through DBUS")
            return ContextEvent("SUCCESS")

    def _connecting_dbus_success_transition(self, event: ContextEvent) \
            -> ContextEvent | None:
        """ Transition to SUBMITTING_START_JOB

        Attempt to connect to submit systemd start job of cache service

        :param event: not used
        :type event: ContextEvent
        :return: Success or FAIL with exit code
        :rtype: ContextEvent | None
        """
        # TODO we will configure this in network_objects
        service_start_job = self.container.start_unit()
        if service_start_job is None:
            self.lgr.error("Failed to submit dns cache service start job")
            self.container.set_exit_code(ExitCode.DBUS_FAILURE)
            return ContextEvent("FAIL")
        self.container.systemd_jobs[service_start_job] = (
            ContextEvent("START_OK"), ContextEvent("START_FAIL"))
        # end of part that will be configured
        self.lgr.info("Successfully submitted dns cache service start job")
        return ContextEvent("SUCCESS")

    def _job_finished_success_transition(self, event: ContextEvent) \
            -> ContextEvent | None:
        """ Transition to POLLING

        Register timeout callback with TIMER_UP event into the main loop

        :param event: Not used
        :type event: ContextEvent
        :return: None
        :rtype: ContextEvent | None
        """
        self.lgr.info("Start job finished successfully, starting polling")
        timer_event = ContextEvent("TIMER_UP", 0)
        GLib.timeout_add_seconds(1,
                                 lambda: self.transition_function(timer_event))
        return None

    def _polling_timer_up_transition(self, event: ContextEvent) \
            -> ContextEvent | None:
        """ Transition to POLLING

        Check whether service is already running and if not then whether
        Dnsconfd is waiting too long already.

        :param event: Event with count of done polls in data
        :type event: ContextEvent
        :return: None or SERVICE_UP if service is up
        :rtype: ContextEvent | None
        """
        if not self.container.dns_mgr.is_ready():
            if event.data == 3:
                self.lgr.critical(f"{self.container.dns_mgr.service_name} did not"
                                  " respond in time, stopping dnsconfd")
                self.container.set_exit_code(ExitCode.SERVICE_FAILURE)
                return ContextEvent("TIMEOUT")
            self.lgr.debug(f"{self.container.dns_mgr.service_name} still not ready, "
                           "scheduling additional poll")
            timer = ContextEvent("TIMER_UP", event.data + 1)
            GLib.timeout_add_seconds(1,
                                     lambda: self.transition_function(timer))
            return None
        else:
            self.lgr.debug("DNS cache service is responding, "
                           "proceeding to setup of resolv.conf")
            return ContextEvent("SERVICE_UP")

    def _running_stop_transition(self, event: ContextEvent) \
            -> ContextEvent | None:
        """ Transition to REVERTING_RESOLV_CONF

        Attempt to revert resolv.conf content

        :param event: Not used
        :type event: ContextEvent
        :return: SUCCESS or FAIL with exit code
        :rtype: ContextEvent | None
        """
        self.lgr.info("Stopping dnsconfd")
        if not self.container.sys_mgr.revert_resolvconf():
            self.container.set_exit_code(ExitCode.RESOLV_CONF_FAILURE)
            return ContextEvent("FAIL")
        return ContextEvent("SUCCESS")

    def _update_transition(self, event: ContextEvent):
        """ Transition to the same state

        Save received network_objects and stay in the current state

        :param event: event with interface config in data
        :type event: ContextEvent
        :return: None
        :rtype: ContextEvent | None
        """
        if event.data is None:
            return None
        self.container.servers = event.data
        return None