include ../../common/json_utils
include ../../../app/core/tasks/common

type
  AsyncActivityNotificationLoadTaskArg = ref object of QObjectTaskArg
    cursor: string
    limit: int
    group: ActivityCenterGroup
    readType: ActivityCenterReadType

const asyncActivityNotificationLoadTask: Task = proc(argEncoded: string) {.gcsafe, nimcall.} =
  let arg = decode[AsyncActivityNotificationLoadTaskArg](argEncoded)
  let activityNotificationsCallResult = backend.activityCenterNotificationsByGroup(newJString(arg.cursor), arg.limit, arg.group.int, arg.readType.int)

  let responseJson = %*{
    "activityNotifications": activityNotificationsCallResult.result
  }
  arg.finish(responseJson)
