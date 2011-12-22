Utils = {};

Utils.formatLogTStamp = function(mseconds) {
  var date = new Date(mseconds);
  var weekDays = "Sun Mon Tue Wed Thu Fri Sat".split(' ');
  var monthNames = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(' ');

  function _2digits(d) {
    d += 100;
    return String(d).substring(1);
  }

  return [
    "<strong>", _2digits(date.getHours()), ':', _2digits(date.getMinutes()),
    ':', _2digits(date.getSeconds()), "</strong> - ", weekDays[date.getDay()],
    ' ', monthNames[date.getMonth()], ' ', date.getDate(), ', ',
    date.getFullYear()].join('');
};
