USE PyDemo;
GO


IF EXISTS(SELECT * FROM sys.procedures WHERE name = 'uspOverbooking')
	DROP PROCEDURE report.uspOverbooking;
GO


CREATE PROCEDURE report.uspOverbooking
(
	@PracticeName				VARCHAR(20),
	@DepartmentName				VARCHAR(20),
	@ProviderKey				INT,
	@AppointmentStartDate		DATE,
	@AppointmentEndDate			DATE,
	@OverbookingThreshold		DECIMAL(8, 4)
)
AS
BEGIN

	--	Fix incorrect parameters
	IF @OverbookingThreshold > 1
		SET @OverbookingThreshold = @OverbookingThreshold / 100;


	IF @AppointmentStartDate <= CAST(SYSDATETIME() AS DATE)
		SET @AppointmentStartDate = CAST(SYSDATETIME() AS DATE);


	IF @AppointmentEndDate <= CAST(SYSDATETIME() AS DATE)
		SET @AppointmentEndDate = CAST(SYSDATETIME() AS DATE);


	DECLARE
		@AppointmentStartDateKey	INT,
		@AppointmentEndDateKey		INT,
		@StatisticsStartDate		DATE,
		@StatisticsStartDateKey		INT,
		@StatisticsEndDate			DATE,
		@StatisticsEndDateKey		INT;


	SET @AppointmentStartDateKey = dbo.ufnCalendarDateKey(@AppointmentStartDate);
	SET @AppointmentEndDateKey = dbo.ufnCalendarDateKey(@AppointmentEndDate);

	SET @StatisticsStartDate = DATEADD(dd, -180, CAST(SYSDATETIME() AS DATE));
	SET @StatisticsEndDate = DATEADD(dd, -1, CAST(SYSDATETIME() AS DATE));

	SET @StatisticsStartDateKey = dbo.ufnCalendarDateKey(@StatisticsStartDate);
	SET @StatisticsEndDateKey = dbo.ufnCalendarDateKey(@StatisticsEndDate);

	
	IF EXISTS(SELECT * FROM sys.tables WHERE name = 'tmpAppointments')
		DROP TABLE dbo.tmpAppointments;


	WITH Summary
	(
		ProviderKey,
		AppointmentDateKey,
		TotalAppointments
	)
	AS
	(
		SELECT
			Appt.ProviderKey,
			Appt.AppointmentDateKey,
			TotalAppointments = SUM(Appt.AppointmentCount)
		FROM
			fact.Appointment Appt
				INNER JOIN
			dim.Department Dept
				ON Appt.DepartmentKey = Dept.DepartmentKey
				INNER JOIN
			dim.Provider Prov
				ON Appt.ProviderKey = Prov.ProviderKey
		WHERE
			Appt.ProviderKey <> -1
			AND
			(@PracticeName = '<All Practices>'
				OR
				Dept.Practice = @PracticeName)
			AND
			(@DepartmentName = '<All Departments>'
				OR
				Dept.Department = @DepartmentName)
			AND
			(@ProviderKey = -1
				OR
				Appt.ProviderKey = @ProviderKey)
			AND
			Appt.AppointmentDateKey BETWEEN @AppointmentStartDateKey AND @AppointmentEndDateKey
		GROUP BY
			Appt.ProviderKey,
			Appt.AppointmentDateKey
	),
	NoShow
	(
		ProviderKey,
		NoShowRate
	)
	AS
	(
		SELECT
			Appt.ProviderKey,
			NoShowRate = CAST(SUM(Appt.NoShowAppointmentCount) AS DECIMAL(16, 4)) / CAST(SUM(Appt.AppointmentCount) AS DECIMAL(16, 4))
		FROM
			fact.Appointment Appt
				INNER JOIN
			dim.Department Dept
				On Appt.DepartmentKey = Dept.DepartmentKey
		WHERE
			(@PracticeName = '<All Practices>'
				OR
				Dept.Practice = @PracticeName)
			AND
			(@DepartmentName = '<All Departments>'
				OR
				Dept.Department = @DepartmentName)
			AND
			(@ProviderKey = -1
				OR
				Appt.ProviderKey = @ProviderKey)
			AND
			Appt.AppointmentDateKey BETWEEN @StatisticsStartDateKey AND @StatisticsEndDateKey
		GROUP BY
			Appt.ProviderKey
	)
	SELECT
		Summ.ProviderKey,
		Summ.AppointmentDateKey,
		Summ.TotalAppointments,
		ShowUpRate = 1 - ISNULL(Nos.NoShowRate, 0),
		ExpectedAppointments = 0,
		OverbookingThreshold = @OverbookingThreshold,
		AppointmentsPerDay = ISNULL(Prov.AppointmentsPerDay, 0),
		OverbookingSlotsAllowed = 0
	INTO
		dbo.tmpAppointments
	FROM
		Summary Summ
			LEFT JOIN
		NoShow Nos
			ON Summ.ProviderKey = Nos.ProviderKey
			LEFT JOIN
		dim.Provider Prov
			ON Summ.ProviderKey = Prov.ProviderKey
	ORDER BY
		ProviderKey,
		AppointmentDateKey;



	SELECT
		*
	INTO
		#tmpOverbooking
	FROM
		OPENROWSET('SQLNCLI', 'Server=(local);Trusted_Connection=yes;', N'
			EXEC sp_execute_external_script
				@language			= N''Python'',
				@script				= N''
import numpy as np
import pandas as pd
from scipy.stats import binom

myQuery["ExpectedAppointments"] = 0
myQuery["ExpectedAppointments"] = binom.ppf(q = myQuery["OverbookingThreshold"], n = myQuery["TotalAppointments"], p = myQuery["ShowUpRate"])
myQuery["OverbookingSlotsAllowed"] = myQuery["TotalAppointments"] - myQuery["ExpectedAppointments"]
print(pd.DataFrame(myQuery))
Results = pd.DataFrame(myQuery)'',
				@input_data_1		= N''
					SELECT
						ProviderKey,
						AppointmentDateKey,
						TotalAppointments,
						ShowUpRate = CAST(ShowUpRate AS FLOAT),
						ExpectedAppointments,
						OverbookingThreshold = CAST(OverbookingThreshold AS FLOAT),
						AppointmentsPerDay,
						OverbookingSlotsAllowed
					FROM
						PyDemo.dbo.tmpAppointments;'',
				@input_data_1_name	= N''myQuery'',
				@output_data_1_name	= N''Results''
			WITH RESULT SETS
			((
		"ProviderKey"				INT NOT NULL,
		"AppointmentDateKey"		INT NOT NULL,
		"TotalAppointments"			INT NOT NULL,
		"ShowUpRate"				NUMERIC(6, 4) NOT NULL,
		"ExpectedAppointments"		INT NOT NULL,
		"OverbookingThreshold"		NUMERIC(6, 4) NOT NULL,
		"AppointmentsPerDay"		INT NOT NULL,
		"OverbookingSlotsAllowed"	INT NOT NULL
			));');


	SELECT
		Prov.ProviderName,
		Prov.ProviderSpecialty,
		AppointmentDate = Cal.CalendarDate,
		Ovr.TotalAppointments,
		Ovr.ShowUpRate,
		Ovr.ExpectedAppointments,
		Ovr.OverbookingThreshold,
		Ovr.AppointmentsPerDay,
		Ovr.OverbookingSlotsAllowed,
		TotalFreeSlots = Ovr.AppointmentsPerDay - Ovr.TotalAppointments + Ovr.OverbookingSlotsAllowed
	FROM
		#tmpOverbooking Ovr
			INNER JOIN
		dim.Provider Prov
			ON Ovr.ProviderKey = Prov.ProviderKey
			INNER JOIN
		dim.Calendar Cal
			ON Ovr.AppointmentDateKey = Cal.CalendarKey;

	DROP TABLE dbo.tmpAppointments;
	DROP TABLE #tmpOverbooking;

END;

GO


