package services
{
	import com.distriqt.extension.dialog.Dialog;
	import com.distriqt.extension.dialog.DialogView;
	import com.distriqt.extension.dialog.builders.AlertBuilder;
	import com.distriqt.extension.dialog.events.DialogViewEvent;
	import com.distriqt.extension.dialog.objects.DialogAction;
	import com.distriqt.extension.notifications.Notifications;
	import com.distriqt.extension.notifications.builders.NotificationBuilder;
	import com.distriqt.extension.notifications.events.NotificationEvent;
	
	import flash.events.EventDispatcher;
	import flash.events.TimerEvent;
	import flash.utils.Timer;
	
	import Utilities.Trace;
	
	import databaseclasses.BgReading;
	import databaseclasses.Calibration;
	import databaseclasses.CommonSettings;
	import databaseclasses.Sensor;
	
	import events.CalibrationServiceEvent;
	import events.NotificationServiceEvent;
	import events.TransmitterServiceEvent;
	
	import model.ModelLocator;
	
	/**
	 * listens for bgreadings, at each bgreading user is asked to enter bg value<br>
	 * after two bgreadings, calibration.initialcalibration will be called and then this service will stop. 
	 */
	public class CalibrationService extends EventDispatcher
	{
		[ResourceBundle("calibrationservice")]
		[ResourceBundle("general")]
		
		private static var _instance:CalibrationService = new CalibrationService();
		private static var bgLevel1:Number;
		private static var timeStampOfFirstBgLevel:Number;
		private static var timerForWaitCalibration:Timer;
		
		private static const MAXIMUM_WAIT_FOR_CALIBRATION_IN_SECONDS:int = 60;
		
		
		public static function get instance():CalibrationService {
			return _instance;
		}
		
		public function CalibrationService() {
			if (_instance != null) {
				throw new Error("CalibrationService class constructor can not be used");	
			}
		}
		
		public static function init():void {
			myTrace("init");
			bgLevel1 = Number.NaN;
			timeStampOfFirstBgLevel = new Number(0);
			TransmitterService.instance.addEventListener(TransmitterServiceEvent.BGREADING_EVENT, bgReadingReceived);
			NotificationService.instance.addEventListener(NotificationServiceEvent.NOTIFICATION_EVENT, notificationReceived);
			myTrace("finished init");
		}
		
		private static function notificationReceived(event:NotificationServiceEvent):void {
			myTrace("notificationReceived");
			if (event != null) {//not sure why checking, this would mean NotificationService received a null object, shouldn't happen
				var notificationEvent:NotificationEvent = event.data as NotificationEvent;
				if (notificationEvent.id == NotificationService.ID_FOR_REQUEST_CALIBRATION) {
					myTrace("in notificationReceived with ID_FOR_REQUEST_CALIBRATION");
					//we don't need to do anything with the bgreading, but we need to ask the user for a calibration
					if (((new Date()).valueOf() - timeStampOfFirstBgLevel) > (7 * 60 * 1000 + 100)) { //previous measurement was more than 7 minutes ago , restart
						myTrace("previous measurement was more than 7 minutes ago , restart");
						timeStampOfFirstBgLevel = new Number(0);
						bgLevel1 = Number.NaN;
					}
					//create alert to get the user's input
					var alert:DialogView = Dialog.service.create(
						new AlertBuilder()
						.setTitle(isNaN(bgLevel1) ? ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_first_calibration_title") : ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_second_calibration_title"))
						.setMessage(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_calibration"))
						.addTextField("",ModelLocator.resourceManagerInstance.getString("calibrationservice",ModelLocator.resourceManagerInstance.getString("calibrationservice","blood_glucose_calibration_value")), false, CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_DO_MGDL) == "true" ? 4:2)
						.addOption("Ok", DialogAction.STYLE_POSITIVE, 0)
						.addOption(ModelLocator.resourceManagerInstance.getString("general","cancel"), DialogAction.STYLE_CANCEL, 1)
						.build()
					);
					alert.addEventListener(DialogViewEvent.CLOSED, intialCalibrationValueEntered);
					alert.addEventListener(DialogViewEvent.CANCELLED, cancellation);
					//setting maximum wait which means in fact user will have two times this period to calibrate
					//because also the notification remains 60 seconds
					DialogService.addDialog(alert, MAXIMUM_WAIT_FOR_CALIBRATION_IN_SECONDS);
				}
			}
		}
		
		public static function stop():void {
		}
		
		private static function bgReadingReceived(be:TransmitterServiceEvent):void {
			myTrace("in bgReadingReceived");

			if (Sensor.getActiveSensor() == null) {
				myTrace("bgReadingReceived, but sensor is null, returning");
				return;
			}
			//if there's already more than two calibrations, then there's no need anymore to request initial calibration
			if (Calibration.allForSensor().length < 2) {
				myTrace("Calibration.allForSensor().length < 2");
				if ((new Date()).valueOf() - Sensor.getActiveSensor().startedAt < 2 * 3600 * 1000) {
					myTrace("CalibrationService : bgreading received but sensor age < 2 hours, so ignoring");
				} else {
					//because the timer based function timerForWaitCalibration doesn't always work as expected
					NotificationService.updateAllNotifications(null);
					
					//launch a notifcation but wait maximum MAXIMUM_WAIT_FOR_CALIBRATION_IN_SECONDS
					if (timerForWaitCalibration != null) {
						if (timerForWaitCalibration.running) {
							timerForWaitCalibration.stop();					
						}
					}
					timerForWaitCalibration = new Timer(MAXIMUM_WAIT_FOR_CALIBRATION_IN_SECONDS * 1000, 1);
					timerForWaitCalibration.addEventListener(TimerEvent.TIMER, removeInitialCalibrationRequestNotification);
					timerForWaitCalibration.start();
					
					//launch a notification
					//don't do it via the notificationservice, this could result in the notification being cleared but not recreated (NotificationService.updateAllNotifications)
					//the notification doesn't need to open any action, the dialog is create when the user opens the notification, or if the app is in the foreground, as soon as the notification is build. 
					//Only do this if be!= null, because if be == null, then it means this function was called after having entered an invalid number in the dialog, so user is using the app, no need for a notification
					if (be != null) {
						myTrace("Launching notification ID_FOR_REQUEST_CALIBRATION");
						Notifications.service.notify(
							new NotificationBuilder()
							.setId(NotificationService.ID_FOR_REQUEST_CALIBRATION)
							.setAlert(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_calibration_title"))
							.setTitle(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_calibration_title"))
							.setBody(isNaN(bgLevel1) ? ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_first_calibration_title") : ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_second_calibration_title"))
							.enableVibration(true)
							.enableLights(true)
							.build());
					} else {
						myTrace("opening dialog to request calibration");
						var alert:DialogView = Dialog.service.create(
							new AlertBuilder()
							.setTitle(isNaN(bgLevel1) ? ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_first_calibration_title") : ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_second_calibration_title"))
							.setMessage(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_calibration"))
							.addTextField("",ModelLocator.resourceManagerInstance.getString("calibrationservice",ModelLocator.resourceManagerInstance.getString("calibrationservice","blood_glucose_calibration_value")))
							.addOption("Ok", DialogAction.STYLE_POSITIVE, 0)
							.addOption(ModelLocator.resourceManagerInstance.getString("general","cancel"), DialogAction.STYLE_CANCEL, 1)
							.build()
						);
						alert.addEventListener(DialogViewEvent.CLOSED, intialCalibrationValueEntered);
						alert.addEventListener(DialogViewEvent.CANCELLED, cancellation);
						//setting maximum wait which means in fact user will have two times this period to calibrate
						//because also the notification remains 60 seconds
						DialogService.addDialog(alert, MAXIMUM_WAIT_FOR_CALIBRATION_IN_SECONDS);
					}
				}
			}
		}
		
		private static function removeInitialCalibrationRequestNotification (event:TimerEvent):void {
			//user didn't give input on time, dialog is closed by DialogService
			//but also notification needs to be removed, call to update will remove this notification
			myTrace("in removeInitialCalibrationRequestNotification");
			NotificationService.updateAllNotifications(null);
		}
		
		private static function cancellation(event:DialogViewEvent):void {
		}
		
		private static function intialCalibrationValueEntered(event:DialogViewEvent):void {
			myTrace("intialCalibrationValueEntered");
			if (event.index == 1) {
				return;
			}
			
			//this will force clear of calibration request notification, if it exists
			NotificationService.updateAllNotifications(null);
			
			var asNumber:Number = new Number(event.values[0] as String);
			if (isNaN(asNumber)) {
				//add the warning message
				var alert:DialogView = Dialog.service.create(
					new AlertBuilder()
					.setTitle(ModelLocator.resourceManagerInstance.getString("calibrationservice","invalid_value"))
					.setMessage(ModelLocator.resourceManagerInstance.getString("calibrationservice","value_should_be_numeric"))
					.addOption("Ok", DialogAction.STYLE_POSITIVE, 0)
					.build()
				);
				DialogService.addDialog(alert);
				//and ask again a value
				bgReadingReceived(null);
			} else {
				if(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_DO_MGDL) != "true") {
					asNumber = asNumber * BgReading.MMOLL_TO_MGDL; 	
				}
				if (isNaN(bgLevel1)) {
					bgLevel1 = asNumber;
					timeStampOfFirstBgLevel = (new Date()).valueOf();
				} else {
					Calibration.initialCalibration(bgLevel1, timeStampOfFirstBgLevel, asNumber, (new Date()).valueOf());
					var calibrationServiceEvent:CalibrationServiceEvent = new CalibrationServiceEvent(CalibrationServiceEvent.INITIAL_CALIBRATION_EVENT);
					_instance.dispatchEvent(calibrationServiceEvent);
					
					//reset values for the case that the sensor is stopped and restarted
					bgLevel1 = Number.NaN;
					timeStampOfFirstBgLevel = new Number(0);
				}
			}
		}
		
		/**
		 * will create an alertdialog to ask for a calibration 
		 */
		private static function initialCalibrate():void {
			myTrace("initialCalibrate");
			var alert:DialogView = Dialog.service.create(
				new AlertBuilder()
				.setTitle(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_calibration_title"))
				.setMessage(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_calibration"))
				.addTextField("",ModelLocator.resourceManagerInstance.getString("calibrationservice",ModelLocator.resourceManagerInstance.getString("calibrationservice","blood_glucose_calibration_value")), false, CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_DO_MGDL) == "true" ? 4:2)
				.addOption("Ok", DialogAction.STYLE_POSITIVE, 0)
				.addOption(ModelLocator.resourceManagerInstance.getString("general","cancel"), DialogAction.STYLE_CANCEL, 1)
				.build()
			);
			alert.addEventListener(DialogViewEvent.CLOSED, calibrationValueEntered);
			alert.addEventListener(DialogViewEvent.CANCELLED, cancellation);
			DialogService.addDialog(alert, 60);
		}
		
		/**
		 * if override = true, then a check will be done if there was a calibration in the last 60 minutes and if so the last calibration will be overriden<br>
		 * if override = false, then there's no calibration override, no matter the timing of the last calibration<br>
		 * <br>
		 * if checklast30minutes = true, then it will be checked if there were readings in the last 30 minutes<br>
		 * if checklast30minutes = false, then it will not be checked if there were readings in the last 30 minutes<br>
		 * <br>
		 * if addSnoozeOption = true, then an action will be added to the dialog which allows snoozing, the snoozeFunction should be non null and is called when the user choses that action
		 */
		public static function calibrationOnRequest(override:Boolean = true, checklast30minutes:Boolean = true, addSnoozeOption:Boolean = false, snoozeFunction:Function = null):void {
			myTrace(" in calibrationOnRequest");
			//check if there's 2 readings the last 30 minutes
			if (BgReading.last30Minutes().length < 2) {
				myTrace(" in calibrationOnRequest, BgReading.last30Minutes().length < 2");
				var alert:DialogView = Dialog.service.create(
					new AlertBuilder()
					.setTitle(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_calibration_title"))
					.setMessage(ModelLocator.resourceManagerInstance.getString("calibrationservice","can_not_calibrate_right_now"))
					.addOption("Ok", DialogAction.STYLE_POSITIVE, 0)
					.build()
				);
				DialogService.addDialog(alert, 60);
			} else { //check if it's an override calibration
				if (((new Date()).valueOf() - (Calibration.latest(2).getItemAt(0) as Calibration).timestamp < (1000 * 60 * 60)) && override) {
					var alert:DialogView = Dialog.service.create(
						new AlertBuilder()
						.setTitle(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_calibration_title_with_override"))
						.setMessage(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_bg_value_with_override"))
						.addTextField("", ModelLocator.resourceManagerInstance.getString("calibrationservice", "blood_glucose_calibration_value"), false, CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_DO_MGDL) == "true" ? 4:2)
						.addOption(ModelLocator.resourceManagerInstance.getString("general","cancel"), DialogAction.STYLE_CANCEL, 1)
						.addOption("Ok", DialogAction.STYLE_POSITIVE, 0)
						.build()
					);
					alert.addEventListener(DialogViewEvent.CLOSED, calibrationDialogClosedWithOverride);
					alert.addEventListener(DialogViewEvent.CANCELLED, cancellation);
					
					DialogService.addDialog(alert);
					
					function cancellation(event:DialogViewEvent):void {
					}
					
					function calibrationDialogClosedWithOverride(event:DialogViewEvent):void {
						if (event.index == 1) {
							//it's a cancel
						} else if (event.index == 0) {
							var asNumber:Number = new Number(event.values[0] as String);
							if (isNaN(asNumber)) {
								var alert:DialogView = Dialog.service.create(
									new AlertBuilder()
									.setTitle(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_calibration_title"))
									.setMessage(ModelLocator.resourceManagerInstance.getString("calibrationservice","value_should_be_numeric"))
									.addOption("Ok", DialogAction.STYLE_POSITIVE, 0)
									.build()
								);
								DialogService.addDialog(alert);
								//and ask again a value
								calibrationOnRequest(override);
							} else {
								if(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_DO_MGDL) != "true") {
									asNumber = asNumber * BgReading.MMOLL_TO_MGDL; 	
								}
								Calibration.clearLastCalibration();
								var newcalibration:Calibration = Calibration.create(asNumber).saveToDatabaseSynchronous();
								var calibrationServiceEvent:CalibrationServiceEvent = new CalibrationServiceEvent(CalibrationServiceEvent.NEW_CALIBRATION_EVENT);
								_instance.dispatchEvent(calibrationServiceEvent);
								myTrace("calibration override, new one = created : " + newcalibration.print("   "));
							}
						}
					}
				} else {
					var alertBuilder:AlertBuilder = 
						new AlertBuilder()
						.setTitle(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_calibration_title"))
						.setMessage(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_bg_value_without_override"))
						.addTextField("",ModelLocator.resourceManagerInstance.getString("calibrationservice","blood_glucose_calibration_value"), false, CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_DO_MGDL) == "true" ? 4:2)//4 is phone,2 is numeric but still sith characters also
						.addOption(ModelLocator.resourceManagerInstance.getString("general","cancel"), DialogAction.STYLE_CANCEL, 1)
						.addOption("Ok", DialogAction.STYLE_POSITIVE, 2);
					if (addSnoozeOption) {
						alertBuilder.addOption(ModelLocator.resourceManagerInstance.getString("notificationservice","snooze_for_snoozin_alarm_in_notification_screen"), DialogAction.STYLE_POSITIVE, 0);
					}
					var alert:DialogView = Dialog.service.create(
						alertBuilder.build()
					);
					alert.addEventListener(DialogViewEvent.CLOSED, calibrationDialogClosedWithoutOverride);
					alert.addEventListener(DialogViewEvent.CANCELLED, cancellation2);
					
					DialogService.addDialog(alert);
					
					function cancellation2(event:DialogViewEvent):void {
					}
					
					function calibrationDialogClosedWithoutOverride(event:DialogViewEvent):void {
						if (event.index == 1) {
							return;
						} else if (event.index == 2) {
							var asNumber:Number = new Number(event.values[0] as String);
							if (isNaN(asNumber)) {
								var alert:DialogView = Dialog.service.create(
									new AlertBuilder()
									.setTitle(ModelLocator.resourceManagerInstance.getString("calibrationservice","enter_calibration_title"))
									.setMessage(ModelLocator.resourceManagerInstance.getString("calibrationservice","value_should_be_numeric"))
									.addOption("Ok", DialogAction.STYLE_POSITIVE, 0)
									.build()
								);
								DialogService.addDialog(alert);
								//and ask again a value
								calibrationOnRequest(override);
							} else {
								if(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_DO_MGDL) != "true") {
									asNumber = asNumber * BgReading.MMOLL_TO_MGDL; 	
								}
								var newcalibration:Calibration = Calibration.create(asNumber).saveToDatabaseSynchronous();
								_instance.dispatchEvent(new CalibrationServiceEvent(CalibrationServiceEvent.NEW_CALIBRATION_EVENT));
								myTrace("Calibration created : " + newcalibration.print("   "));
							}
						} else if (event.index == 0) {
							myTrace("in calibrationOnRequest, subfunction calibrationDialogClosed");
							snoozeFunction.call();
						}
					}
				}
			}
		}
		
		private static function calibrationValueEntered(event:DialogViewEvent):void {
			if (event.index == 1) {
				return;
			}
			var asNumber:Number = new Number(event.values[0] as String);
			if (isNaN(asNumber)) {
				//add the warning message
				var alert:DialogView = Dialog.service.create(
					new AlertBuilder()
					.setTitle(ModelLocator.resourceManagerInstance.getString("calibrationservice","invalid_value"))
					.setMessage(ModelLocator.resourceManagerInstance.getString("calibrationservice","value_should_be_numeric"))
					.addOption("Ok", DialogAction.STYLE_POSITIVE, 0)
					.build()
				);
				DialogService.addDialog(alert);
				//and ask again a value
				initialCalibrate();
			} else {
				if(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_DO_MGDL) != "true") {
					asNumber = asNumber * BgReading.MMOLL_TO_MGDL; 	
				}
				var calibration:Calibration = Calibration.create(asNumber).saveToDatabaseSynchronous();
				myTrace("Calibration created : " + calibration.print("   "));
			}
		}
		
		private static function myTrace(log:String):void {
			Trace.myTrace("CalibrationService.as", log);
		}
	}
}